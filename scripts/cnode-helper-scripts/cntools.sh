#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086,SC2154,SC2034,SC2012,SC2140,SC2028,SC1091

. "$(dirname $0)"/env offline

# legacy config (deprecated and removed in future major version update)
if [[ -f "$(dirname $0)"/cntools.config ]]; then
  ! . "$(dirname $0)"/cntools.config && exit 1
  clear && waitToProceed "${FG_RED}cntools.config deprecated and will be removed in future major version!${NC}\n"\
    "Uncomment and set any customization in User Variables section of cntools.sh instead."\
    "Once done, delete cntools.config file to get rid of this message.\n"\
    "press any key to proceed .."
fi

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#TIMEOUT_NO_OF_SLOTS=600 # used when waiting for a new block to be created

# log cntools activities (comment or set empty to disable)
# LOG_DIR set in env file
#CNTOOLS_LOG="${LOG_DIR}/cntools-history.log"

# kes rotation warning (in seconds)
# if disabled KES check will be skipped on startup
#CHECK_KES=false
#KES_ALERT_PERIOD=172800 # default 2 days
#KES_WARNING_PERIOD=604800 # default 7 days

# Default Transaction TTL (slots after which transaction will expire from queue) to use
#TX_TTL=3600

# limit for extended wallet selection menu filtering (balance check and delegation status)
# if more wallets exist than limit set these checks will be disabled to improve performance
#WALLET_SELECTION_FILTER_LIMIT=10

# enable or disable chattr used to protect keys from being overwritten [true|false] (not supported on all systems)
# if disabled standard read-only permission is set instead
#ENABLE_CHATTR=true

# enable or disable dialog used to help in file/dir selection by providing a gui to see available files and folders. [true|false] (not supported on all systems)
# if disabled standard tty input is used
#ENABLE_DIALOG=false

# enable advanced/developer features like metadata transactions, multi-asset management etc. [true|false] (not needed for SPO usage)
#ENABLE_ADVANCED=false

######################################
# Do NOT modify code below           #
######################################

########## Global tasks ###########################################

# General exit handler
cleanup() {
  sleep 0.1
  if { true >&6; } 2<> /dev/null; then
    exec 1>&6 2>&7 3>&- 6>&- 7>&- 8>&- 9>&- # Restore stdout/stderr and close tmp file descriptors
  fi
  [[ -n $1 ]] && err=$1 || err=$?
  [[ $err -eq 0 ]] && clear
  [[ -n ${exit_msg} ]] && echo -e "\n${exit_msg}\n" || echo -e "\nCNTools terminated, cleaning up...\n"
  tput cnorm # restore cursor
  tput sgr0  # turn off all attributes
  exit $err
}
trap cleanup HUP INT TERM
STTY_SETTINGS="$(stty -g < /dev/tty)"
trap 'stty "$STTY_SETTINGS" < /dev/tty' EXIT

# Command     : myExit [exit code] [message]
# Description : gracefully handle an exit and restore terminal to original state
myExit() {
  exit_msg="$2"
  cleanup "$1"
}

usage() {
  cat <<-EOF
		Usage: $(basename "$0") [-o] [-a] [-b <branch name>] [-v]
		Koios CNTools - The Cardano SPOs best friend
		
		-o    Activate offline mode - run CNTools in offline mode without node access, a limited set of functions available
		-a    Enable advanced/developer features like metadata transactions, multi-asset management etc (not needed for SPO usage)
		-u    Skip script update check overriding UPDATE_CHECK value in env
		-b    Run CNTools and look for updates on alternate branch instead of master (only for testing/development purposes)
		-v    Print CNTools version
		
		EOF
}

CNTOOLS_MODE="CONNECTED"
ADVANCED_MODE="false"
SKIP_UPDATE=N
PRINT_VERSION="false"
PARENT="$(dirname $0)"
[[ -f "${PARENT}"/.env_branch ]] && BRANCH="$(cat "${PARENT}"/.env_branch)" || BRANCH="master"

while getopts :oaub:v opt; do
  case ${opt} in
    o ) CNTOOLS_MODE="OFFLINE" ;;
    a ) ADVANCED_MODE="true" ;;
    u ) SKIP_UPDATE=Y ;;
    b ) echo "${OPTARG}" > "${PARENT}"/.env_branch ;;
    v ) PRINT_VERSION="true" ;;
    \? ) myExit 1 "$(usage)" ;;
    esac
done
shift $((OPTIND -1))

#######################################################
# Version Check                                       #
#######################################################
clear

if [[ ! -f "${PARENT}"/env ]]; then
  echo -e "\nCommon env file missing: ${PARENT}/env"
  echo -e "This is a mandatory prerequisite, please install with guild-deploy.sh or manually download from GitHub\n"
  myExit 1
fi

# Source env file, re-sourced later
if [[ "${CNTOOLS_MODE}" == "OFFLINE" ]]; then
  . "${PARENT}"/env offline &>/dev/null
else
  . "${PARENT}"/env &>/dev/null
fi

# Source cntools.library to populate defaults for CNTools
! . "${PARENT}"/cntools.library && myExit 1

[[ ${PRINT_VERSION} = "true" ]] && myExit 0 "CNTools v${CNTOOLS_VERSION} (branch: $([[ -f "${PARENT}"/.env_branch ]] && cat "${PARENT}"/.env_branch || echo "master"))"

# Do some checks when run in connected mode
if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
  # check to see if there are any updates available
  clear
  if [[ ${UPDATE_CHECK} = Y && ${SKIP_UPDATE} != Y ]]; then 

    echo "Checking for script updates..."

    # Check availability of checkUpdate function
    if [[ ! $(command -v checkUpdate) ]]; then
      myExit 1 "\nCould not find checkUpdate function in env, make sure you're using official docos for installation!"
    fi

    # check for env update
    ENV_UPDATED=N
    checkUpdate env N N N
    case $? in
      1) ENV_UPDATED=Y ;;
      2) myExit 1 ;;
    esac

    # source common env variables in case it was updated
    . "${PARENT}"/env
    case $? in
      1) myExit 1 "ERROR: CNTools failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" ;;
      2) clear ;;
    esac
    
    # check for cntools update
    checkUpdate "${PARENT}"/cntools.library "${ENV_UPDATED}" Y N
    case $? in
      1) checkUpdate "${PARENT}"/cntools.sh Y
         if [[ $? = 2 ]]; then
           echo -e "\n${FG_RED}ERROR${NC}: Update check of cntools.sh against GitHub failed!"
           waitToProceed
         fi
         $0 "$@" "-u"; myExit 0 ;; # re-launch script with same args skipping update check
      2) echo -e "\n${FG_RED}ERROR${NC}: Update check of cntools.library against GitHub failed!"
         waitToProceed ;;
    esac
    
    # check if CNTools was recently updated, if so show whats new
    if curl -s -f -m ${CURL_TIMEOUT} -o "${TMP_DIR}"/cntools-changelog.md "${URL_DOCS}/cntools-changelog.md"; then
      if ! cmp -s "${TMP_DIR}"/cntools-changelog.md "${PARENT}/cntools-changelog.md"; then
        # Latest changes not shown, show whats new and copy changelog
        clear 
        sleep 0.1
        if [[ ! -f "${PARENT}/cntools-changelog.md" ]]; then 
          # special case for first installation or 5.0.0 upgrade, print release notes until previous major version
          echo -e "~ CNTools - What's New ~\n\n" "$(sed -n "/\[${CNTOOLS_MAJOR_VERSION}\.${CNTOOLS_MINOR_VERSION}\.${CNTOOLS_PATCH_VERSION}\]/,/\[$((CNTOOLS_MAJOR_VERSION-1))\.[0-9]\.[0-9]\]/p" "${TMP_DIR}"/cntools-changelog.md | head -n -2)" | less -X
        else
          # print release notes from current until previously installed version
          [[ $(cat "${PARENT}/cntools-changelog.md") =~ \[([[:digit:]]+)\.([[:digit:]]+)\.([[:digit:]]+)\] ]]
          cat <(echo -e "~ CNTools - What's New ~\n") <(awk "1;/\[${BASH_REMATCH[1]}\.${BASH_REMATCH[2]}\.${BASH_REMATCH[3]}\]/{exit}" "${TMP_DIR}"/cntools-changelog.md | head -n -2 | tail -n +7) <(echo -e "\n [Press 'q' to quit and proceed to CNTools main menu]\n") | less -X
        fi
        cp "${TMP_DIR}"/cntools-changelog.md "${PARENT}/cntools-changelog.md"
      fi
    else
      echo -e "\n${FG_RED}ERROR${NC}: failed to download changelog from GitHub!"
      waitToProceed
    fi
  fi

  # Validate protocol parameters
  if grep -q "Network.Socket.connect" <<< "${PROT_PARAMS}"; then
    myExit 1 "${FG_YELLOW}WARN${NC}: node socket path wrongly configured or node not running, please verify that socket set in env file match what is used to run the node\n\n${FG_BLUE}INFO${NC}: re-run CNTools in offline mode with -o parameter if you want to access CNTools with limited functionality"
  elif [[ -z "${PROT_PARAMS}" ]] || ! jq -er . <<< "${PROT_PARAMS}" &>/dev/null; then
    myExit 1 "${FG_YELLOW}WARN${NC}: failed to query protocol parameters, ensure your node is running with correct genesis (the node needs to be in sync to 1 epoch after the hardfork)\n\nError message: ${PROT_PARAMS}\n\n${FG_BLUE}INFO${NC}: re-run CNTools in offline mode with -o parameter if you want to access CNTools with limited functionality"
  fi
  echo "${PROT_PARAMS}" > "${TMP_DIR}"/protparams.json
fi

# Test if koios is reachable , otherwise - unset KOIOS_API
test_koios

archiveLog # archive current log and cleanup log archive folder

# check for required command line tools
if ! cmdAvailable "curl" || \
   ! cmdAvailable "jq" || \
   ! cmdAvailable "bc" || \
   ! cmdAvailable "sed" || \
   ! cmdAvailable "awk" || \
   ! cmdAvailable "column" || \
   ! protectionPreRequisites; then myExit 1 "Missing one or more of the required command line tools, press any key to exit"
fi

# check that bash version is > 4.4.0
[[ $(bash --version | head -n 1) =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || myExit 1 "Unable to get BASH version"
if ! versionCheck "4.4.0" "${BASH_REMATCH[1]}"; then
  myExit 1 "BASH does not meet the minimum required version of ${FG_LBLUE}4.4.0${NC}, found ${FG_LBLUE}${BASH_REMATCH[1]}${NC}\n\nPlease upgrade to a newer Linux distribution or compile latest BASH following official docs.\n\nINSTALL:  https://www.gnu.org/software/bash/manual/html_node/Installing-Bash.html\nDOWNLOAD: http://git.savannah.gnu.org/cgit/bash.git/ (latest stable TAG)"
fi

exec 6>&1 # Link file descriptor #6 with normal stdout.
exec 7>&2 # Link file descriptor #7 with normal stderr.
[[ -n ${CNTOOLS_LOG} ]] && exec > >( tee >( while read -r line; do logln "INFO" "${line}"; done ) )
[[ -n ${CNTOOLS_LOG} ]] && exec 2> >( tee >( while read -r line; do logln "ERROR" "${line}"; done ) >&2 )
[[ -n ${CNTOOLS_LOG} ]] && exec 3> >( tee >( while read -r line; do logln "DEBUG" "${line}"; done ) >&6 )
exec 8>&1 # Link file descriptor #8 with custom stdout.
exec 9>&2 # Link file descriptor #9 with custom stderr.

# check if there are pools in need of KES key rotation
clear
kes_rotation_needed="no"
if [[ ${CHECK_KES} = true ]]; then

  while IFS= read -r -d '' pool; do
    unset pool_kes_start
    [[ ${CNTOOLS_MODE} = "CONNECTED" ]] && getNodeMetrics
    [[ (-z ${remaining_kes_periods} || ${remaining_kes_periods} -eq 0) && -f "${pool}/${POOL_CURRENT_KES_START}" ]] && unset remaining_kes_periods && pool_kes_start="$(cat "${pool}/${POOL_CURRENT_KES_START}")"  
  
    if ! kesExpiration ${pool_kes_start}; then println ERROR "${FG_RED}ERROR${NC}: failure during KES calculation for ${FG_GREEN}$(basename ${pool})${NC}" && waitForInput && continue; fi

    if [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
      kes_rotation_needed="yes"
      println "\n** WARNING **\nPool ${FG_GREEN}$(basename ${pool})${NC} in need of KES key rotation"
      if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
        println DEBUG "${FG_RED}Keys expired!${NC} : ${FG_RED}$(timeLeft ${expiration_time_sec_diff:1})${NC} ago"
      else
        println DEBUG "Remaining KES periods : ${FG_RED}${remaining_kes_periods}${NC}"
        println DEBUG "Time left             : ${FG_RED}$(timeLeft ${expiration_time_sec_diff})${NC}"
      fi
    elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
      kes_rotation_needed="yes"
      println DEBUG "\nPool ${FG_GREEN}$(basename ${pool})${NC} soon in need of KES key rotation"
      println DEBUG "Remaining KES periods : ${FG_YELLOW}${remaining_kes_periods}${NC}"
      println DEBUG "Time left             : ${FG_YELLOW}$(timeLeft ${expiration_time_sec_diff})${NC}"
    fi
  done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  [[ ${kes_rotation_needed} = "yes" ]] && waitForInput
  
fi

# Verify that shelley transition epoch was properly identified by env
if [[ ${SHELLEY_TRANS_EPOCH} -lt 0 ]]; then # unknown network
  clear
  myExit 1 "${FG_YELLOW}WARN${NC}: This is an unknown network, please manually set SHELLEY_TRANS_EPOCH variable in env file"
fi

###################################################################

function main {
  while true; do # Main loop
    # Start with a clean slate after each completed or canceled command excluding .dialogrc from purge
    find "${TMP_DIR:?}" -type f -not \( -name 'protparams.json' -o -name '.dialogrc' -o -name "offline_tx*" -o -name "*_cntools_backup*" -o -name "metadata_*" -o -name "asset*" \) -delete
    unset IFS
    clear
    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
      println "$(printf " >> Koios CNTools v%s - %s - ${FG_GREEN}%s${NC} <<" "${CNTOOLS_VERSION}" "${NETWORK_NAME}" "${CNTOOLS_MODE}")"
    else
      println "$(printf " >> Koios CNTools v%s - %s - ${FG_LBLUE}%s${NC} <<" "${CNTOOLS_VERSION}" "${NETWORK_NAME}" "${CNTOOLS_MODE}")"
    fi
    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println OFF " Main Menu    Telegram Announcement / Support channel: ${FG_YELLOW}t.me/CardanoKoios/9759${NC}\n"\
			" ) Wallet      - create, show, remove and protect wallets"\
			" ) Funds       - send, withdraw and delegate"\
			" ) Pool        - pool creation and management"\
			" ) Transaction - Sign and Submit a cold transaction (hybrid/offline mode)"\
			"$([[ -f "${BLOCKLOG_DB}" ]] && echo " ) Blocks      - show core node leader schedule & block production statistics")"\
			" ) Backup      - backup & restore of wallet/pool/config"\
			"$([[ ${ADVANCED_MODE} = true ]] && echo " ) Advanced    - Developer and advanced features: metadata, multi-assets, ...")"\
			" ) Refresh     - reload home screen content"\
			"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println DEBUG "$(printf "%84s" "Epoch $(getEpoch) - $(timeLeft "$(timeUntilNextEpoch)") until next")"
    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println DEBUG " What would you like to do?"
    else
      getNodeMetrics
      tip_diff=$(( $(getSlotTipRef) - slotnum ))
      slot_interval=$(slotInterval)
      if [[ ${tip_diff} -le ${slot_interval} ]]; then
        println DEBUG "$(printf " What would you like to do? %$((84-29-${#tip_diff}-3))s ${FG_GREEN}%s${NC}" "Node Sync:" "${tip_diff} :)")"
      elif [[ ${tip_diff} -le $(( slot_interval * 2 )) ]]; then
        println DEBUG "$(printf " What would you like to do? %$((84-29-${#tip_diff}-3))s ${FG_YELLOW}%s${NC}" "Node Sync:" "${tip_diff} :|")"
      else
        println DEBUG "$(printf " What would you like to do? %$((84-29-${#tip_diff}-3))s ${FG_RED}%s${NC}" "Node Sync:" "${tip_diff} :(")"
      fi
    fi
    echo
    select_opt "[w] Wallet" "[f] Funds" "[p] Pool" "[t] Transaction" "$([[ -f "${BLOCKLOG_DB}" ]] && echo "[b] Blocks")" "[z] Backup & Restore" "$([[ ${ADVANCED_MODE} = true ]] && echo "[a] Advanced")" "[r] Refresh" "[q] Quit"
    case ${selected_value} in
      "[w]"*) OPERATION="wallet" ;;
      "[f]"*) OPERATION="funds" ;;
      "[p]"*) OPERATION="pool" ;;
      "[t]"*) OPERATION="transaction" ;;
      "[b]"*) OPERATION="blocks" ;;
      "[z]"*) OPERATION="backup" ;;
      "[a]"*) OPERATION="advanced" ;;
      "[r]"*) continue ;;
      "[q]"*) myExit 0 "CNTools closed!" ;;
    esac
    case $OPERATION in
      wallet)
        while true; do # Wallet loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> WALLET"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Wallet Management\n\n ) New         - create a new wallet"\
						" ) Import      - import a Daedalus/Yoroi 24/25 mnemonic or Ledger/Trezor HW wallet"\
						" ) Register    - register a wallet on chain"\
						" ) De-Register - De-Register (retire) a registered wallet"\
						" ) List        - list all available wallets in a compact view"\
						" ) Show        - show detailed view of a specific wallet"\
						" ) Remove      - remove a wallet"\
						" ) Decrypt     - remove write protection and decrypt wallet"\
						" ) Encrypt     - encrypt wallet keys and make all files immutable"\
						"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Wallet Operation\n"
          select_opt "[n] New" "[i] Import" "[r] Register" "[z] De-Register" "[l] List" "[s] Show" "[x] Remove" "[d] Decrypt" "[e] Encrypt" "[h] Home"
          case $? in
            0) SUBCOMMAND="new" ;;
            1) SUBCOMMAND="import" ;;
            2) SUBCOMMAND="register" ;;
            3) SUBCOMMAND="deregister" ;;
            4) SUBCOMMAND="list" ;;
            5) SUBCOMMAND="show" ;;
            6) SUBCOMMAND="remove" ;;
            7) SUBCOMMAND="decrypt" ;;
            8) SUBCOMMAND="encrypt" ;;
            9) break ;;
          esac
          case $SUBCOMMAND in
            new)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> NEW"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              getAnswerAnyCust wallet_name "Name of new wallet" wallet_name
              # Remove unwanted characters from wallet name
              wallet_name=${wallet_name//[^[:alnum:]]/_}
              if [[ -z "${wallet_name}" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: Empty wallet name, please retry!"
                waitForInput && continue
              fi
              echo
              if ! mkdir -p "${WALLET_FOLDER}/${wallet_name}"; then
                println ERROR "${FG_RED}ERROR${NC}: Failed to create directory for wallet:\n${WALLET_FOLDER}/${wallet_name}"
                waitForInput && continue
              fi
              # Wallet key filenames
              payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
              payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
              stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
              stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
              if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -type f -print0 | wc -c) -gt 0 ]]; then
                println "${FG_RED}WARN${NC}: A wallet ${FG_GREEN}$wallet_name${NC} already exists"
                println "      Choose another name or delete the existing one"
                waitForInput && continue
              fi
              println ACTION "${CCLI} address key-gen --verification-key-file ${payment_vk_file} --signing-key-file ${payment_sk_file}"
              if ! ${CCLI} address key-gen --verification-key-file "${payment_vk_file}" --signing-key-file "${payment_sk_file}"; then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during payment key creation!"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitForInput && continue
              fi
              println ACTION "${CCLI} stake-address key-gen --verification-key-file ${stake_vk_file} --signing-key-file ${stake_sk_file}"
              if ! ${CCLI} stake-address key-gen --verification-key-file "${stake_vk_file}" --signing-key-file "${stake_sk_file}"; then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during stake key creation!"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitForInput && continue
              fi
              chmod 600 "${WALLET_FOLDER}/${wallet_name}/"*
              getBaseAddress ${wallet_name}
              getPayAddress ${wallet_name}
              getRewardAddress ${wallet_name}
              println "New Wallet         : ${FG_GREEN}${wallet_name}${NC}"
              println "Address            : ${FG_LGRAY}${base_addr}${NC}"
              println "Enterprise Address : ${FG_LGRAY}${pay_addr}${NC}"
              println DEBUG "\nYou can now send and receive Ada using the above addresses."
              println DEBUG "Note that Enterprise Address will not take part in staking."
              println DEBUG "Wallet will be automatically registered on chain if you\nchoose to delegate or pledge wallet when registering a stake pool."
              waitForInput && continue
              ;; ###################################################################
            import)
              while true; do # Wallet >> Import loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> WALLET >> IMPORT"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Wallet Import\n"\
									" ) Mnemonic  - Daedalus/Yoroi 24 or 25 word mnemonic"\
									" ) HW Wallet - Ledger/Trezor hardware wallet"\
									"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select Wallet Import Operation\n"
                select_opt "[m] Mnemonic" "[w] HW Wallet" "[b] Back" "[h] Home"
                case $? in
                  0) SUBCOMMAND="mnemonic" ;;
                  1) SUBCOMMAND="hardware" ;;
                  2) break ;;
                  3) break 2 ;;
                esac
                case $SUBCOMMAND in
                  mnemonic)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> WALLET >> IMPORT >> MNEMONIC"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    if ! cmdAvailable "bech32" &>/dev/null || \
                      ! cmdAvailable "cardano-address" &>/dev/null; then
                      println ERROR "${FG_RED}ERROR${NC}: bech32 and/or cardano-address not found in '\$PATH'" 
                      println ERROR "Please run updated guild-deploy.sh and re-build/re-download cardano-node"
                      waitForInput && continue
                    fi
                    getAnswerAnyCust wallet_name "Name of imported wallet"
                    # Remove unwanted characters from wallet name
                    wallet_name=${wallet_name//[^[:alnum:]]/_}
                    if [[ -z "${wallet_name}" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: Empty wallet name, please retry!"
                      waitForInput && continue
                    fi
                    echo
                    if ! mkdir -p "${WALLET_FOLDER}/${wallet_name}"; then
                      println ERROR "${FG_RED}ERROR${NC}: Failed to create directory for wallet:\n${WALLET_FOLDER}/${wallet_name}"
                      waitForInput && continue
                    fi
                    if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -type f -print0 | wc -c) -gt 0 ]]; then
                      println "${FG_RED}WARN${NC}: A wallet ${FG_GREEN}$wallet_name${NC} already exists"
                      println "      Choose another name or delete the existing one"
                      waitForInput && continue
                    fi
                    getAnswerAnyCust mnemonic false "24 or 15 word mnemonic(space separated)"
                    echo
                    IFS=" " read -r -a words <<< "${mnemonic}"
                    if [[ ${#words[@]} -ne 24 ]] && [[ ${#words[@]} -ne 15 ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: 24 or 15 words expected, found ${FG_RED}${#words[@]}${NC}"
                      echo && safeDel "${WALLET_FOLDER}/${wallet_name}"
                      unset mnemonic; unset words
                      waitForInput && continue
                    fi
                    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
                    payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
                    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
                    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
                    caddr_v="$(cardano-address -v | awk '{print $1}')"
                    [[ "${caddr_v}" == 3* ]] && caddr_arg="--with-chain-code" || caddr_arg=""
                    if ! root_prv=$(cardano-address key from-recovery-phrase Shelley <<< ${mnemonic}); then
                      echo && safeDel "${WALLET_FOLDER}/${wallet_name}"
                      unset mnemonic; unset words
                      waitForInput && continue
                    fi
                    unset mnemonic; unset words
                    payment_xprv=$(cardano-address key child 1852H/1815H/0H/0/0 <<< ${root_prv})
                    stake_xprv=$(cardano-address key child 1852H/1815H/0H/2/0 <<< ${root_prv})
                    payment_xpub=$(cardano-address key public ${caddr_arg} <<< ${payment_xprv})
                    stake_xpub=$(cardano-address key public ${caddr_arg} <<< ${stake_xprv})
                    [[ "${NWMAGIC}" == "764824073" ]] && network_tag=1 || network_tag=0
                    base_addr_candidate=$(cardano-address address delegation ${stake_xpub} <<< "$(cardano-address address payment --network-tag ${network_tag} <<< ${payment_xpub})")
                    if [[ "${caddr_v}" == 2* ]] && [[ "${NWMAGIC}" != "764824073" ]]; then
                      println LOG "TestNet, converting address to 'addr_test'"
                      base_addr_candidate=$(bech32 addr_test <<< ${base_addr_candidate})
                    fi
                    println LOG "Base address candidate = ${base_addr_candidate}"
                    println LOG "Address Inspection:\n$(cardano-address address inspect <<< ${base_addr_candidate})"
                    pes_key=$(bech32 <<< ${payment_xprv} | cut -b -128)$(bech32 <<< ${payment_xpub})
                    ses_key=$(bech32 <<< ${stake_xprv} | cut -b -128)$(bech32 <<< ${stake_xpub})
                    cat <<-EOF > "${payment_sk_file}"
											{
											    "type": "PaymentExtendedSigningKeyShelley_ed25519_bip32",
											    "description": "Payment Signing Key",
											    "cborHex": "5880${pes_key}"
											}
											EOF
                    cat <<-EOF > "${stake_sk_file}"
											{
											    "type": "StakeExtendedSigningKeyShelley_ed25519_bip32",
											    "description": "",
											    "cborHex": "5880${ses_key}"
											}
											EOF
                    println ACTION "${CCLI} key verification-key --signing-key-file ${payment_sk_file} --verification-key-file ${TMP_DIR}/payment.evkey"
                    if ! ${CCLI} key verification-key --signing-key-file "${payment_sk_file}" --verification-key-file "${TMP_DIR}/payment.evkey"; then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during payment signing key extraction!"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitForInput && continue
                    fi
                    println ACTION "${CCLI} key verification-key --signing-key-file ${stake_sk_file} --verification-key-file ${TMP_DIR}/stake.evkey"
                    if ! ${CCLI} key verification-key --signing-key-file "${stake_sk_file}" --verification-key-file "${TMP_DIR}/stake.evkey"; then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during stake signing key extraction!"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitForInput && continue
                    fi
                    println ACTION "${CCLI} key non-extended-key --extended-verification-key-file ${TMP_DIR}/payment.evkey --verification-key-file ${payment_vk_file}"
                    if ! ${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/payment.evkey" --verification-key-file "${payment_vk_file}"; then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during payment verification key extraction!"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitForInput && continue
                    fi
                    println ACTION "${CCLI} key non-extended-key --extended-verification-key-file ${TMP_DIR}/stake.evkey --verification-key-file ${stake_vk_file}"
                    if ! ${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/stake.evkey" --verification-key-file "${stake_vk_file}"; then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during stake verification key extraction!"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitForInput && continue
                    fi
                    chmod 600 "${WALLET_FOLDER}/${wallet_name}/"*
                    getBaseAddress ${wallet_name}
                    getPayAddress ${wallet_name}
                    getRewardAddress ${wallet_name}
                    if [[ ${base_addr} != "${base_addr_candidate}" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: base address generated doesn't match base address candidate."
                      println ERROR "base_addr[${FG_LGRAY}${base_addr}${NC}]\n!=\nbase_addr_candidate[${FG_LGRAY}${base_addr_candidate}${NC}]"
                      println ERROR "Create a GitHub issue and include log file from failed CNTools session."
                      echo && safeDel "${WALLET_FOLDER}/${wallet_name}"
                      waitForInput && continue
                    fi
                    echo
                    println "Wallet Imported    : ${FG_GREEN}${wallet_name}${NC}"
                    println "Address            : ${FG_LGRAY}${base_addr}${NC}"
                    println "Enterprise Address : ${FG_LGRAY}${pay_addr}${NC}"
                    echo
                    println DEBUG "You can now send and receive Ada using the above addresses. Note that Enterprise Address will not take part in staking"
                    println DEBUG "Wallet will be automatically registered on chain if you choose to delegate or pledge wallet when registering a stake pool"
                    echo
                    println DEBUG "${FG_YELLOW}Using a mnemonic imported wallet in CNTools comes with a few limitations${NC}"
                    echo
                    println DEBUG "Only the first address in the HD wallet is extracted and because of this the following apply:"
                    println DEBUG " ${FG_LGRAY}>${NC} Address above should match the first address seen in Daedalus/Yoroi, please verify!!!"
                    println DEBUG " ${FG_LGRAY}>${NC} If restored wallet contain funds since before, send all Ada through Daedalus/Yoroi to address shown in CNTools"
                    println DEBUG " ${FG_LGRAY}>${NC} Only use receive address shown in CNTools"
                    println DEBUG " ${FG_LGRAY}>${NC} Only spend Ada from CNTools, if spent through Daedalus/Yoroi balance seen in CNTools wont match"
                    echo
                    println DEBUG "Some of the advantages of using a mnemonic imported wallet instead of CLI are:"
                    println DEBUG " ${FG_LGRAY}>${NC} Wallet can be restored from saved 24 or 15 word mnemonic if keys are lost/deleted"
                    println DEBUG " ${FG_LGRAY}>${NC} Track rewards in Daedalus/Yoroi"
                    echo
                    println DEBUG "Please read more about HD wallets at:"
                    println DEBUG "https://cardano-community.github.io/support-faq/wallets?id=heirarchical-deterministic-hd-wallets"
                    waitForInput && continue
                    ;; ###################################################################

                  hardware)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> WALLET >> IMPORT >> HARDWARE WALLET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    println DEBUG "Supported HW wallets: Ledger S, Ledger X, Trezor Model T"
                    println "Is your hardware wallet one of these models?"
                    select_opt "[y] Yes" "[n] No"
                    case $? in
                      0) : ;; # do nothing
                      1) waitForInput "Unsupported hardware wallet, press any key to return home" && continue ;;
                    esac
                    echo
                    if ! cmdAvailable "cardano-hw-cli" &>/dev/null; then
                      println ERROR "${FG_RED}ERROR${NC}: cardano-hw-cli executable not found in path!"
                      println ERROR "Please run '${FG_YELLOW}guild-deploy.sh -s w${NC}' to add hardware wallet support and install Vaccumlabs cardano-hw-cli, '${FG_YELLOW}guild-deploy.sh -h${NC}' shows all available options"
                      waitForInput && continue
                    fi
                    if [[ ! -x $(command -v cardano-hw-cli) ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: cardano-hw-cli binary doesn't have execution persmission, please fix!"
                      waitForInput && continue
                    fi
                    if ! HWCLIversionCheck; then waitForInput && continue; fi
                    getAnswerAnyCust wallet_name "Name of imported wallet"
                    # Remove unwanted characters from wallet name
                    wallet_name=${wallet_name//[^[:alnum:]]/_}
                    if [[ -z "${wallet_name}" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: Empty wallet name, please retry!"
                      waitForInput && continue
                    fi
                    if ! mkdir -p "${WALLET_FOLDER}/${wallet_name}"; then
                      println ERROR "${FG_RED}ERROR${NC}: Failed to create directory for wallet:\n${WALLET_FOLDER}/${wallet_name}"
                      waitForInput && continue
                    fi
                    if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -type f -print0 | wc -c) -gt 0 ]]; then
                      println "${FG_RED}WARN${NC}: A wallet ${FG_GREEN}$wallet_name${NC} already exists"
                      println "      Choose another name or delete the existing one"
                      waitForInput && continue
                    fi
                    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_HW_PAY_SK_FILENAME}"
                    payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
                    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_HW_STAKE_SK_FILENAME}"
                    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
                    if ! unlockHWDevice "extract ${FG_LGRAY}payment keys${NC}"; then safeDel "${WALLET_FOLDER}/${wallet_name}"; continue; fi
                    println ACTION "cardano-hw-cli address key-gen --path 1852H/1815H/0H/0/0 --verification-key-file ${payment_vk_file} --hw-signing-file ${payment_sk_file}"
                    if ! cardano-hw-cli address key-gen --path 1852H/1815H/0H/0/0 --verification-key-file "${payment_vk_file}" --hw-signing-file "${payment_sk_file}"; then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during payment key extraction!"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitForInput && continue
                    fi
                    jq '.description = "Payment Hardware Verification Key"' "${payment_vk_file}" > "${TMP_DIR}/$(basename "${payment_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${payment_vk_file}").tmp" "${payment_vk_file}"
                    println DEBUG "${FG_BLUE}INFO${NC}: repeat and follow instructions on hardware device to extract the ${FG_LGRAY}stake keys${NC}"
                    println ACTION "cardano-hw-cli address key-gen --path 1852H/1815H/0H/2/0 --verification-key-file ${stake_vk_file} --hw-signing-file ${stake_sk_file}"
                    if ! cardano-hw-cli address key-gen --path 1852H/1815H/0H/2/0 --verification-key-file "${stake_vk_file}" --hw-signing-file "${stake_sk_file}"; then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during stake key extraction!"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitForInput && continue
                    fi
                    jq '.description = "Stake Hardware Verification Key"' "${stake_vk_file}" > "${TMP_DIR}/$(basename "${stake_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${stake_vk_file}").tmp" "${stake_vk_file}"
                    getBaseAddress ${wallet_name}
                    getPayAddress ${wallet_name}
                    getRewardAddress ${wallet_name}
                    echo
                    println "HW Wallet Imported : ${FG_GREEN}${wallet_name}${NC}"
                    println "Address            : ${FG_LGRAY}${base_addr}${NC}"
                    println "Enterprise Address : ${FG_LGRAY}${pay_addr}${NC}"
                    echo
                    println DEBUG "You can now send and receive Ada using the above addresses. Note that Enterprise Address will not take part in staking"
                    echo
                    println DEBUG "All transaction signing is now done through hardware device, please follow directions in both CNTools and the device display!"
                    println DEBUG "${FG_YELLOW}Using an imported hardware wallet in CNTools comes with a few limitations${NC}"
                    echo
                    println DEBUG "Most operations like delegation and sending funds is seamless. For pool registration/modification however the following apply:"
                    println DEBUG " ${FG_LGRAY}>${NC} Pool owner has to be a CLI wallet with enough funds to pay for pool registration deposit and transaction fee"
                    println DEBUG " ${FG_LGRAY}>${NC} Add the hardware wallet containing the pledge as a multi-owner to the pool"
                    println DEBUG " ${FG_LGRAY}>${NC} The hardware wallet can be used as the reward wallet, but has to be included as a multi-owner if it should be counted to pledge"
                    echo
                    println DEBUG "Only the first address in the HD wallet is extracted and because of this the following apply if also synced with Daedalus/Yoroi:"
                    println DEBUG " ${FG_LGRAY}>${NC} Address above should match the first address seen in Daedalus/Yoroi, please verify!!!"
                    println DEBUG " ${FG_LGRAY}>${NC} If restored wallet contain funds since before, send all Ada through Daedalus/Yoroi to address shown in CNTools"
                    println DEBUG " ${FG_LGRAY}>${NC} Only use the address shown in CNTools to receive funds"
                    println DEBUG " ${FG_LGRAY}>${NC} Only spend Ada from CNTools, if spent through Daedalus/Yoroi balance seen in CNTools wont match"
                    waitForInput && continue
                    ;; ###################################################################
                esac # wallet >> import sub OPERATION
              done # Wallet >> Import loop
              ;; ###################################################################
            register)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> REGISTER"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitForInput && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "# Select wallet to register (only non-registered wallets shown)"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "non-reg" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
                esac
              else
                selectWallet "non-reg" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              getBaseAddress ${wallet_name}
              getBalance ${base_addr}
              if [[ ${assets[lovelace]} -gt 0 ]]; then
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} Ada" "Funds in wallet:"  "$(formatLovelace ${assets[lovelace]})")"
                fi
              else
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                stakeAddressDeposit=$(jq -r '.stakeAddressDeposit' <<< "${PROT_PARAMS}")
                println DEBUG "Funds for key deposit($(formatLovelace ${stakeAddressDeposit}) Ada) + transaction fee needed to register the wallet"
                waitForInput && continue
              fi
              if ! registerStakeWallet ${wallet_name} "true"; then
                waitForInput && continue
              fi
              println "\n${FG_GREEN}${wallet_name}${NC} successfully registered on chain!"
              waitForInput && continue
              ;; ###################################################################
            deregister)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> DE-REGISTER"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitForInput && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "# Select wallet to de-register (only registered wallets shown)"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "reg" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
                esac
              else
                selectWallet "reg" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              getRewards ${wallet_name}
              if [[ "${reward_lovelace}" -gt 0 ]]; then
                println "\n${FG_YELLOW}WARN${NC}: wallet has unclaimed rewards, please use 'Funds >> Withdraw Rewards' before de-registration to claim your rewards"
                waitForInput && continue
              fi
              getBaseAddress ${wallet_name}
              getBalance ${base_addr}
              if [[ ${assets[lovelace]} -le 0 ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                println ERROR "Funds for transaction fee needed to deregister the wallet"
                waitForInput && continue
              fi
              if ! deregisterStakeWallet; then
                [[ -f ${stake_dereg_file} ]] && rm -f ${stake_dereg_file}
                waitForInput && continue
              fi
              echo
              if ! verifyTx ${base_addr}; then waitForInput && continue; fi
              echo
              println "${FG_GREEN}${wallet_name}${NC} successfully de-registered from chain!"
              println "Key deposit fee that will be refunded : ${FG_LBLUE}$(formatLovelace ${stakeAddressDeposit})${NC} Ada"
              waitForInput && continue
              ;; ###################################################################
            list)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> LIST"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, wallet balance not shown!"
              fi
              while IFS= read -r -d '' wallet; do
                wallet_name=$(basename ${wallet})
                enc_files=$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c)
                if [[ ${CNTOOLS_MODE} = "CONNECTED" ]] && isWalletRegistered ${wallet_name}; then registered="yes"; else registered="no"; fi
                echo
                if [[ ${enc_files} -gt 0 && ${registered} = "yes" ]]; then
                  println "${FG_GREEN}${wallet_name}${NC} - ${FG_LGRAY}REGISTERED${NC} (${FG_YELLOW}encrypted${NC})"
                elif [[ ${registered} = "yes" ]]; then
                  println "${FG_GREEN}${wallet_name}${NC} - ${FG_LGRAY}REGISTERED${NC}"
                elif [[ ${enc_files} -gt 0 ]]; then
                  println "${FG_GREEN}${wallet_name}${NC} (${FG_YELLOW}encrypted${NC})"
                else
                  println "${FG_GREEN}${wallet_name}${NC}"
                fi
                getBaseAddress ${wallet_name}
                getPayAddress ${wallet_name}
                if [[ -z ${base_addr} && -z ${pay_addr} ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: wallet missing pay/base addr files or vkey files to generate them!"
                  continue
                fi
                if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                  [[ -n ${base_addr} ]] && println "$(printf "%-15s : ${FG_LGRAY}%s${NC}" "Address"  "${base_addr}")"
                  [[ -n ${pay_addr} ]] && println "$(printf "%-15s : ${FG_LGRAY}%s${NC}" "Enterprise Addr"  "${pay_addr}")"
                else
                  if [[ -n ${base_addr} ]]; then
                    getBalance ${base_addr}
                    println "$(printf "%-19s : ${FG_LGRAY}%s${NC}" "Address"  "${base_addr}")"
                    if [[ ${#assets[@]} -eq 1 ]]; then
                      println "$(printf "%-19s : ${FG_LBLUE}%s${NC} Ada" "Funds"  "$(formatLovelace ${assets[lovelace]})")"
                    else
                      println "$(printf "%-19s : ${FG_LBLUE}%s${NC} Ada - ${FG_LBLUE}%s${NC} additional asset(s) on address! [WALLET >> SHOW for details]" "Funds" "$(formatLovelace ${assets[lovelace]})" "$(( ${#assets[@]} - 1 ))")"
                    fi
                  fi
                  if [[ -n ${pay_addr} ]]; then
                    getBalance ${pay_addr}
                    if [[ ${assets[lovelace]} -gt 0 ]]; then
                      println "$(printf "%-19s : ${FG_LGRAY}%s${NC}" "Enterprise Address"  "${pay_addr}")"
                      if [[ ${#assets[@]} -eq 1 ]]; then
                        println "$(printf "%-19s : ${FG_LBLUE}%s${NC} Ada" "Enterprise Funds" "$(formatLovelace ${assets[lovelace]})")"
                      else
                        println "$(printf "%-19s : ${FG_LBLUE}%s${NC} Ada - ${FG_LBLUE}%s${NC} additional asset(s) on address! [WALLET >> SHOW for details]" "Enterprise Funds" "$(formatLovelace ${assets[lovelace]})" "$(( ${#assets[@]} - 1 ))")"
                      fi
                    fi
                  fi
                  if [[ -z ${base_addr} && -z ${pay_addr} ]]; then
                    println "${FG_RED}Not a supported wallet${NC} - genesis address?"
                    println "Use an external script to send funds to a CNTools compatible wallet"
                    continue
                  fi
                  getRewards ${wallet_name}
                  if [[ "${reward_lovelace}" -ge 0 ]]; then
                    println "$(printf "%-19s : ${FG_LBLUE}%s${NC} Ada" "Rewards" "$(formatLovelace ${reward_lovelace})")"
                    delegation_pool_id=$(jq -r '.[0].delegation // empty' <<< "${stake_address_info}")
                    if [[ -n ${delegation_pool_id} ]]; then
                      unset poolName
                      while IFS= read -r -d '' pool; do
                        getPoolID "$(basename ${pool})"
                        if [[ "${pool_id_bech32}" = "${delegation_pool_id}" ]]; then
                          poolName=$(basename ${pool}) && break
                        fi
                      done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
                      println "${FG_RED}Delegated${NC} to ${FG_GREEN}${poolName}${NC} ${FG_LGRAY}(${delegation_pool_id})${NC}"
                    fi
                  fi
                fi
              done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
              waitForInput && continue
              ;; ###################################################################
            show)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> SHOW"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, limited wallet info shown!"
              fi
              tput sc
              selectWallet "none"
              case $? in
                1) waitForInput; continue ;;
                2) continue ;;
              esac
              tput rc && tput ed
              enc_files=$(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c)
              if [[ ${enc_files} -gt 0 ]]; then
                println "Wallet: ${FG_GREEN}${wallet_name}${NC} (${FG_YELLOW}encrypted${NC})"
              else
                println "Wallet: ${FG_GREEN}${wallet_name}${NC}"
              fi
              getBaseAddress ${wallet_name}
              getPayAddress ${wallet_name}
              if [[ -z ${base_addr} && -z ${pay_addr} ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: wallet missing pay/base addr files or vkey files to generate them!"
                waitForInput && continue
              fi
              getRewardAddress ${wallet_name}
              base_lovelace=0
              pay_lovelace=0
              declare -A token_data=()
              declare -A token_name=()
              declare -A assets_total=()
              if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
                # Token Metadata API URLs
                case ${NWMAGIC} in
                  764824073) token_meta_server="https://tokens.cardano.org/metadata/" ;; # mainnet
                  *) token_meta_server="https://metadata.cardano-testnet.iohkdev.io/metadata/" ;; # other test networks
                esac
                for i in {1..2}; do
                  if [[ $i -eq 1 ]]; then 
                    address_type="Base"
                    getBalance ${base_addr} && base_lovelace=${assets[lovelace]}
                  else
                    address_type="Enterprise"
                    getBalance ${pay_addr} && pay_lovelace=${assets[lovelace]}
                  fi
                  [[ $i -eq 2 && ${utxo_cnt} -eq 0 ]] && continue # Dont print Enterprise if empty
                  
                  # loop all assets to query metadata register for token data
                  for asset in "${!assets[@]}"; do
                    assets_total[${asset}]=$(( assets_total[asset] + assets[asset] ))
                    [[ ${asset} = "lovelace" ]] && continue
                    IFS='.' read -ra asset_arr <<< "${asset}"
                    [[ ${#asset_arr[@]} -eq 1 ]] && asset_name="" || asset_name="${asset_arr[1]}"
                    tsubject="${asset_arr[0]}${asset_name}"
                    if tdata=$(curl -sL -f -m ${CURL_TIMEOUT} ${token_meta_server}${tsubject}); then
                      token_data[${asset}]="${tdata}"
                      if tticker=$(jq -er .ticker.value <<< "${tdata}" 2>/dev/null); then token_name[${asset}]="${tticker}"
                      elif tname=$(jq -er .name.value <<< "${tdata}" 2>/dev/null); then token_name[${asset}]="${tname}"
                      fi
                    fi
                  done
                  
                  echo
                  println "${FG_LBLUE}${utxo_cnt} UTxO(s)${NC} found for ${FG_GREEN}${address_type}${NC} Address!"
                  if [[ ${utxo_cnt} -gt 0 ]]; then
                    echo
                    println DEBUG "$(printf "%-67s ${FG_DGRAY}|${NC} %${asset_name_maxlen}s ${FG_DGRAY}|${NC} %-${asset_amount_maxlen}s\n" "UTxO Hash#Index" "Asset" "Amount")"
                    println DEBUG "${FG_DGRAY}$(printf "%68s+%$((asset_name_maxlen+2))s+%$((asset_amount_maxlen+1))s\n" "" "" "" | tr " " "-")${NC}"
                    mapfile -d '' utxos_sorted < <(printf '%s\0' "${!utxos[@]}" | sort -z)
                    for utxo in "${utxos_sorted[@]}"; do
                      IFS='.' read -ra utxo_arr <<< "${utxo}"
                      if [[ ${#utxo_arr[@]} -eq 2 && ${utxo_arr[1]} = " Ada" ]]; then
                        println DEBUG "$(printf "%-67s ${FG_DGRAY}|${NC} ${FG_GREEN}%${asset_name_maxlen}s${NC} ${FG_DGRAY}|${NC} ${FG_LBLUE}%-${asset_amount_maxlen}s${NC}\n" "${utxo_arr[0]}" "Ada" "$(formatLovelace ${utxos["${utxo}"]})")"
                      else
                        [[ ${#utxo_arr[@]} -eq 3 ]] && asset_name="${utxo_arr[2]}" || asset_name=""
                        if [[ -n ${token_name[${utxo_arr[1]}.${asset_name}]} ]]; then
                          tname="${token_name[${utxo_arr[1]}.${asset_name}]}"
                        else
                          tname="$(hexToAscii ${asset_name})"
                        fi
                        ! assets_id_bech32=$(getAssetIDBech32 ${utxo_arr[1]} ${asset_name}) && continue 3
                        println DEBUG "$(printf "${FG_DGRAY}%20s${NC}${FG_LGRAY}%-47s${NC} ${FG_DGRAY}|${NC} ${FG_MAGENTA}%${asset_name_maxlen}s${NC} ${FG_DGRAY}|${NC} ${FG_LBLUE}%-${asset_amount_maxlen}s${NC}\n" "Asset Fingerprint: " "${assets_id_bech32}" "${tname}" "$(formatAsset ${utxos["${utxo}"]})")"
                      fi
                    done
                  fi
                  if [[ ${#assets[@]} -gt 0 ]]; then
                    println "\nASSET SUMMARY: ${FG_LBLUE}${#assets[@]} Asset-Type(s)${NC} $([[ ${#assets[@]} -gt 1 ]] && echo -e "/ ${FG_LBLUE}${#policyIDs[@]} Unique Policy ID(s)${NC}")\n"
                    println DEBUG "$(printf "%${asset_amount_maxlen}s ${FG_DGRAY}|${NC} %-${asset_name_maxlen}s%s\n" "Total Amount" "Asset" "$([[ ${#assets[@]} -gt 1 ]] && echo -e " ${FG_DGRAY}|${NC} Asset Fingerprint")")"
                    println DEBUG "${FG_DGRAY}$(printf "%$((asset_amount_maxlen+1))s+%$((asset_name_maxlen+2))s%s\n" "" "" "$([[ ${#assets[@]} -gt 1 ]] && printf "+%57s" "")" | tr " " "-")${NC}"
                    println DEBUG "$(printf "${FG_LBLUE}%${asset_amount_maxlen}s${NC} ${FG_DGRAY}|${NC} ${FG_GREEN}%-${asset_name_maxlen}s${NC}%s\n" "$(formatLovelace ${assets[lovelace]})" "Ada" "$([[ ${#assets[@]} -gt 1 ]] && echo -n " ${FG_DGRAY}|${NC}")")"
                    mapfile -d '' assets_sorted < <(printf '%s\0' "${!assets[@]}" | sort -z)
                    for asset in "${assets_sorted[@]}"; do
                      [[ ${asset} = "lovelace" ]] && continue
                      IFS='.' read -ra asset_arr <<< "${asset}"
                      [[ ${#asset_arr[@]} -eq 1 ]] && asset_name="" || asset_name="${asset_arr[1]}"
                      if [[ -n ${token_name[${asset_arr[0]}.${asset_name}]} ]]; then
                        tname="${token_name[${asset_arr[0]}.${asset_name}]}"
                      else
                        tname="$(hexToAscii ${asset_name})"
                      fi
                      ! assets_id_bech32=$(getAssetIDBech32 ${asset_arr[0]} ${asset_name}) && continue 2
                      println DEBUG "$(printf "${FG_LBLUE}%${asset_amount_maxlen}s${NC} ${FG_DGRAY}|${NC} ${FG_MAGENTA}%-${asset_name_maxlen}s${NC} ${FG_DGRAY}|${NC} ${FG_LGRAY}%s${NC}\n" "$(formatAsset ${assets["${asset}"]})" "${tname}" "${assets_id_bech32}")"
                    done
                  fi
                done
                
                if [[ ${#assets_total[@]} -gt 1 ]]; then
                  echo -e "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" >&6
                  println DEBUG "ASSET DETAILS & METADATA\n"
                  i=1
                  for asset in "${!assets_total[@]}"; do
                    [[ ${asset} = "lovelace" ]] && continue
                    IFS='.' read -ra asset_arr <<< "${asset}"
                    [[ ${#asset_arr[@]} -eq 1 ]] && asset_name="" || asset_name="${asset_arr[1]}"
                    ! assets_id_bech32=$(getAssetIDBech32 ${asset_arr[0]} ${asset_name}) && continue 2
                    println DEBUG "$(printf "%20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Asset Fingerprint" "${assets_id_bech32}")"
                    if [[ -n ${token_data[${asset}]} ]]; then
                      if jq -er .ticker.value <<< "${token_data[${asset}]}" &>/dev/null; then MetaNameColor=${FG_LGRAY}; MetaTickerColor=${FG_MAGENTA}; else MetaNameColor=${FG_MAGENTA}; MetaTickerColor=${FG_LGRAY}; fi
                      println DEBUG "$(printf "%20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "PolicyID.AssetName" "${asset}")"
                      println DEBUG "$(printf "%-21s${FG_DGRAY}%s${NC}" "" ": # METADATA #")"
                      println DEBUG "  $(printf "%18s ${FG_DGRAY}:${NC} ${MetaNameColor}%s${NC}" "Name" "$(jq -r .name.value <<< "${token_data[${asset}]}")")"
                      println DEBUG "  $(printf "%18s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Description" "$(jq -r .description.value <<< "${token_data[${asset}]}")")"
                      tticker=$(jq -er .ticker.value <<< "${token_data[${asset}]}") && println DEBUG "  $(printf "%18s ${FG_DGRAY}:${NC} ${MetaTickerColor}%s${NC}" "Ticker" "${tticker}")"
                      turl=$(jq -er .url.value <<< "${token_data[${asset}]}") && println DEBUG "  $(printf "%18s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "URL" "${turl}")"
                      if tlogo=$(jq -er .logo.value <<< "${token_data[${asset}]}"); then
                        base64 --decode <<< "${tlogo}" 2>/dev/null > "${TMP_DIR}/${assets_id_bech32}.png"
                        println DEBUG "  $(printf "%18s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Logo" "Extracted to: ${TMP_DIR}/${assets_id_bech32}.png")"
                      fi
                    else
                      println DEBUG "$(printf "%20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}$([[ -n ${asset_name} ]] && echo ".")${FG_LGRAY}%s${NC}$([[ -n ${asset_name} ]] && echo " (")${FG_MAGENTA}%s${NC}$([[ -n ${asset_name} ]] && echo ")")" "PolicyID.AssetName" "${asset_arr[0]}" "${asset_name}" "$(hexToAscii ${asset_name})")"
                      println DEBUG "$(printf "${FG_DGRAY}%22s${NC} ${FG_YELLOW}%s${NC}" ":" "No metadata registered in Cardano token register for this asset")"
                    fi
                    ((i++))
                    [[ ${#assets_total[@]} -gt $i ]] && println OFF "${FG_DGRAY}  -------------------+---------------------------------------------${NC}"
                  done
                fi
                
                echo -e "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" >&6
                if isWalletRegistered ${wallet_name}; then
                  println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_GREEN}%s${NC}" "Registered" "YES")"
                else
                  println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_RED}%s${NC}" "Registered" "NO")"
                fi
              else
                println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Registered" "Unknown")"
              fi

              [[ -n ${base_addr} ]]   && println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Address" "${base_addr}")"
              [[ -n ${pay_addr} ]]    && println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Enterprise Address" "${pay_addr}")"
              [[ -n ${reward_addr} ]] && println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Reward/Stake Address" "${reward_addr}")"
              if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
                if [[ -n ${reward_addr} ]]; then
                  getRewardsFromAddr ${reward_addr}
                  if [[ "${reward_lovelace}" -ge 0 ]]; then
                    println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LBLUE}%s${NC} Ada" "Rewards Available" "$(formatLovelace ${reward_lovelace})")"
                    println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LBLUE}%s${NC} Ada" "Funds + Rewards" "$(formatLovelace $((pay_lovelace + base_lovelace + reward_lovelace)))")"
                  fi
                fi
                if [[ -n ${base_addr} ]]; then getAddressInfo "${base_addr}"; else getAddressInfo "${pay_addr}"; fi
                println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Encoding" "$(jq -r '.encoding' <<< ${address_info})")"
                if [[ -n ${reward_addr} ]]; then delegation_pool_id=$(jq -r '.[0].delegation  // empty' <<< "${stake_address_info}" 2>/dev/null); else unset delegation_pool_id; fi
                if [[ -n ${delegation_pool_id} ]]; then
                  unset poolName
                  while IFS= read -r -d '' pool; do
                    getPoolID "$(basename ${pool})"
                    if [[ "${pool_id_bech32}" = "${delegation_pool_id}" ]]; then
                      poolName=$(basename ${pool}) && break
                    fi
                  done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
                  echo
                  println "${FG_RED}Delegated${NC} to ${FG_GREEN}${poolName}${NC} ${FG_LGRAY}(${delegation_pool_id})${NC}"
                fi
              fi
              if [[ -z ${pay_addr} || -z ${base_addr} || -z ${reward_addr} ]]; then
                echo
                [[ -z ${pay_addr} ]]    && println "${FG_YELLOW}INFO${NC}: '${FG_LGRAY}${WALLET_PAY_ADDR_FILENAME}${NC}' missing and '${FG_LGRAY}${WALLET_PAY_VK_FILENAME}${NC}' to generate it!"
                [[ -z ${base_addr} ]]   && println "${FG_YELLOW}INFO${NC}: '${FG_LGRAY}${WALLET_BASE_ADDR_FILENAME}${NC}' missing and '${FG_LGRAY}${WALLET_PAY_VK_FILENAME}${NC}/${FG_LGRAY}${WALLET_STAKE_VK_FILENAME}${NC}' to generate it!"
                [[ -z ${reward_addr} ]] && println "${FG_YELLOW}INFO${NC}: '${FG_LGRAY}${WALLET_STAKE_ADDR_FILENAME}${NC}' missing and '${FG_LGRAY}${WALLET_STAKE_VK_FILENAME}${NC}' to generate it!"
              fi
              waitForInput && continue
              ;; ###################################################################
            remove)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> REMOVE"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, unable to verify wallet balance"
              fi
              echo
              println DEBUG "# Select wallet to remove"
              selectWallet "none"
              case $? in
                1) waitForInput; continue ;;
                2) continue ;;
              esac
              echo
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "Are you sure to delete wallet ${FG_GREEN}${wallet_name}${NC}?"
                select_opt "[y] Yes" "[n] No"
                case $? in
                  0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
                    ;;
                  1) echo && println "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
                    ;;
                esac
                waitForInput && continue
              fi
              if ! getBaseAddress ${wallet_name} && ! getPayAddress ${wallet_name}; then
                println DEBUG "${FG_RED}WARN${NC}: unable to get address for wallet and do a balance check"
                println DEBUG "\nAre you sure to delete wallet ${FG_GREEN}${wallet_name}${NC} anyway?"
                select_opt "[y] Yes" "[n] No"
                case $? in
                  0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
                    ;;
                  1) echo && println "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
                    ;;
                esac
                waitForInput && continue
              fi
              if [[ -n ${base_addr} ]]; then
                getBalance ${base_addr}
                base_lovelace=${assets[lovelace]}
              else
                base_lovelace=0
              fi
              if [[ -n ${pay_addr} ]]; then
                getBalance ${pay_addr}
                pay_lovelace=${assets[lovelace]}
              else
                pay_lovelace=0
              fi
              getRewards ${wallet_name}
              if [[ ${base_lovelace} -eq 0 && ${pay_lovelace} -eq 0 && ${reward_lovelace} -le 0 ]]; then
                println DEBUG "INFO: This wallet appears to be empty"
                println DEBUG "${FG_RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup\n"
                println DEBUG "Are you sure to delete wallet ${FG_GREEN}${wallet_name}${NC}?"
                select_opt "[y] Yes" "[n] No"
                case $? in
                  0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
                    ;;
                  1) echo && println "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
                    ;;
                esac
              else
                println "${FG_RED}WARN${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not empty!"
                [[ ${base_lovelace} -gt 0 ]] && println "Funds : ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} Ada"
                [[ ${pay_lovelace} -gt 0 ]] && println "Enterprise Funds : ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} Ada"
                [[ ${reward_lovelace} -gt 0 ]] && println "Rewards : ${FG_LBLUE}$(formatLovelace ${reward_lovelace})${NC} Ada"
                echo
                println DEBUG "${FG_RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup\n"
                println DEBUG "Are you sure to delete wallet ${FG_GREEN}${wallet_name}${NC}?"
                select_opt "[y] Yes" "[n] No"
                case $? in
                  0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
                    ;;
                  1) echo && println "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
                    ;;
                esac
              fi
              waitForInput && continue
              ;; ###################################################################
            decrypt)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> DECRYPT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
              println DEBUG "# Select wallet to decrypt"
              selectWallet "encrypted"
              case $? in
                1) waitForInput; continue ;;
                2) continue ;;
              esac
              filesUnlocked=0
              keysDecrypted=0
              echo
              println DEBUG "# Removing write protection from all wallet files"
              while IFS= read -r -d '' file; do
                unlockFile "${file}"
                filesUnlocked=$((++filesUnlocked))
                println DEBUG "${file}"
              done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -print0)
              if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -gt 0 ]]; then
                echo
                println DEBUG "# Decrypting GPG encrypted wallet files"
                echo
                if ! getPasswordCust; then # $password variable populated by getPasswordCust function
                  println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                  waitForInput && continue
                fi
                while IFS= read -r -d '' file; do
                  decryptFile "${file}" "${password}" && \
                  chmod 600 "${file::-4}" && \
                  keysDecrypted=$((++keysDecrypted))
                done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
                unset password
              fi
              echo
              println "Wallet unprotected : ${FG_GREEN}${wallet_name}${NC}"
              println "Files unlocked     : ${FG_LBLUE}${filesUnlocked}${NC}"
              println "Files decrypted    : ${FG_LBLUE}${keysDecrypted}${NC}"
              if [[ ${filesUnlocked} -ne 0 || ${keysDecrypted} -ne 0 ]]; then
                echo
                println DEBUG "${FG_YELLOW}Wallet files are now unprotected${NC}"
                println DEBUG "Use 'WALLET >> ENCRYPT' to re-lock"
              fi
              waitForInput && continue
              ;; ###################################################################
            encrypt)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> ENCRYPT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
              println DEBUG "# Select wallet to encrypt"
              selectWallet "encrypted"
              case $? in
                1) waitForInput; continue ;;
                2) continue ;;
              esac
              filesLocked=0
              keysEncrypted=0
              if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -le 0 ]]; then
                echo
                println DEBUG "# Encrypting sensitive wallet keys with GPG"
                echo
                if ! getPasswordCust confirm; then # $password variable populated by getPasswordCust function
                  println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
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
              else
                echo
                println DEBUG "${FG_YELLOW}NOTE${NC}: found GPG encrypted files in folder, please decrypt/unlock wallet files before encrypting"
                waitForInput && continue
              fi
              echo
              println DEBUG "# Write protecting all wallet keys with 400 permission and if enabled 'chattr +i'"
              while IFS= read -r -d '' file; do
                [[ ${file} = *.addr ]] && continue
                lockFile "${file}"
                filesLocked=$((++filesLocked))
                println DEBUG "${file}"
              done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -print0)
              echo
              println "Wallet protected : ${FG_GREEN}${wallet_name}${NC}"
              println "Files locked     : ${FG_LBLUE}${filesLocked}${NC}"
              println "Files encrypted  : ${FG_LBLUE}${keysEncrypted}${NC}"
              if [[ ${filesLocked} -ne 0 || ${keysEncrypted} -ne 0 ]]; then
                echo
                println DEBUG "${FG_BLUE}INFO${NC}: wallet files are now protected"
                println DEBUG "Use 'WALLET >> DECRYPT' to unlock"
              fi
              waitForInput && continue
              ;; ###################################################################
          esac # wallet sub OPERATION
        done # Wallet loop
        ;; ###################################################################
      funds)
        while true; do # Funds loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> FUNDS"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Handle Funds\n"\
						" ) Send     - send Ada and/or custom Assets from a local wallet"\
						" ) Delegate - delegate wallet to a pool"\
						" ) Withdraw - withdraw earned rewards to base address"\
						"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Funds Operation\n"
          select_opt "[s] Send" "[d] Delegate" "[w] Withdraw Rewards" "[h] Home"
          case $? in
            0) SUBCOMMAND="send" ;;
            1) SUBCOMMAND="delegate" ;;
            2) SUBCOMMAND="withdrawrewards" ;;
            3) break ;;
          esac
          case $SUBCOMMAND in
            send)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> FUNDS >> SEND"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitForInput && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              
              # source wallet
              println DEBUG "# Select ${FG_YELLOW}source${NC} wallet"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "balance" "${WALLET_PAY_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
                esac
              else
                selectWallet "balance" "${WALLET_PAY_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              s_wallet="${wallet_name}"
              s_payment_vk_file="${payment_vk_file}"
              s_payment_sk_file="${payment_sk_file}"
              getBaseAddress ${s_wallet}
              getPayAddress ${s_wallet}
              getBalance ${base_addr}
              base_lovelace=${assets[lovelace]}
              getBalance ${pay_addr}
              pay_lovelace=${assets[lovelace]}
              if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                # Both payment and base address available with funds, let user choose what to use
                println DEBUG "Select source wallet address"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
                select_opt "[b] Base (default)" "[e] Enterprise" "[Esc] Cancel"
                case $? in
                  0) s_addr="${base_addr}" ;;
                  1) s_addr="${pay_addr}" ;;
                  2) continue ;;
                esac
                echo
              elif [[ ${pay_lovelace} -gt 0 ]]; then
                s_addr="${pay_addr}"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} Ada\n" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
              elif [[ ${base_lovelace} -gt 0 ]]; then
                s_addr="${base_addr}"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} Ada\n" "Funds :"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${s_wallet}${NC}"
                waitForInput && continue
              fi
              getBalance ${s_addr}
              declare -gA assets_left=()
              for asset in "${!assets[@]}"; do
                assets_left[${asset}]=${assets[${asset}]}
              done
              minUTxOValue=$(jq -r '.minUTxOValue //1000000' <<< "${PROT_PARAMS}")

              # Amount
              println DEBUG "\n# Amount to Send (in Ada)"
              println DEBUG " Valid entry:"
              println DEBUG "   ${FG_LGRAY}>${NC} Integer (e.g. 15) or Decimal (e.g. 956.1235), commas allowed as thousand separator"
              println DEBUG "   ${FG_LGRAY}>${NC} The string '${FG_YELLOW}all${NC}' sends all available funds in source wallet"
              println DEBUG " Multi-Asset Info:"
              println DEBUG "   ${FG_LGRAY}>${NC} If '${FG_YELLOW}all${NC}' is used and the wallet contain multiple assets,"
              println DEBUG "   ${FG_LGRAY}>${NC} then all assets will be transferred(incl Ada) to the destination address"
              println DEBUG " Minimum Amount: ${FG_LBLUE}$(formatLovelace ${minUTxOValue})${NC} Ada"
              println DEBUG "   ${FG_LGRAY}>${NC} To calculate the minimum Ada required if additional assets/tokens are to be sent,"\
								"     make a dummy transaction with ${FG_LBLUE}0${NC} Ada selecting the tokens to send with the correct amount\n"
              getAnswerAnyCust amountADA "Amount (Ada)"
              amountADA="${amountADA//,}"
              echo
              if  [[ ${amountADA} != "all" ]]; then
                if ! AdaToLovelace "${amountADA}" >/dev/null; then
                  waitForInput && continue
                fi
                amount_lovelace=$(AdaToLovelace "${amountADA}")
                [[ ${amount_lovelace} -gt ${assets[lovelace]} ]] && println ERROR "${FG_RED}ERROR${NC}: not enough funds on address, ${FG_LBLUE}$(formatLovelace ${assets[lovelace]})${NC} Ada available but trying to send ${FG_LBLUE}$(formatLovelace ${amount_lovelace})${NC} Ada" && waitForInput && continue
                println DEBUG "Fee payed by sender? [else amount sent is reduced]"
                select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
                case $? in
                  0) include_fee="no" ;;
                  1) include_fee="yes" ;;
                  2) continue ;;
                esac
              else
                amount_lovelace=${assets[lovelace]}
                println DEBUG "Ada to send set to total supply: ${FG_LBLUE}$(formatLovelace ${amount_lovelace})${NC}"
                include_fee="yes"
              fi
              echo
              declare -gA assets_to_send=()
              if [[ ${amount_lovelace} -eq ${assets[lovelace]} ]]; then
                unset assets_left
                for asset in "${!assets[@]}"; do
                  assets_to_send[${asset}]=${assets[${asset}]} # add all assets, e.g clone assets array to assets_to_send
                done
              else
                assets_left[lovelace]=$(( assets_left[lovelace] - amount_lovelace ))
                assets_to_send[lovelace]=${amount_lovelace}
              fi
              
              # Add additional assets to transaction?
              if [[ ${#assets_left[@]} -gt 0 && ${#assets[@]} -gt 1 ]]; then
                println DEBUG "Additional assets found on address, include in transaction?"
                asset_cnt=1
                select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                case $? in
                  0) : ;;
                  1) declare -A assets_on_addr=()
                    for asset in "${!assets[@]}"; do
                      [[ ${asset} = "lovelace" ]] && continue
                      IFS='.' read -ra asset_arr <<< "${asset}"
                      assets_on_addr["${asset} ($(hexToAscii ${asset_arr[1]}))"]=0 # only interested in the key
                    done
                    while true; do
                      select_opt "${!assets_on_addr[@]}" "[Esc] Cancel"
                      selection=$?
                      [[ ${selected_value} = "[Esc] Cancel" ]] && continue 2
                      IFS=' ' read -ra selection_arr <<< "${selected_value}"
                      println DEBUG "Available to send: ${FG_LBLUE}$(formatAsset ${assets[${selection_arr[0]}]})${NC}"
                      getAnswerAnyCust asset_amount "Amount (commas allowed as thousand separator)"
                      asset_amount="${asset_amount//,}"
                      [[ ${asset_amount} = "all" ]] && asset_amount=${assets[${selection_arr[0]}]}
                      if ! isNumber ${asset_amount}; then println ERROR "${FG_RED}ERROR${NC}: invalid number, non digit characters found!" && continue; fi
                      if [[ ${asset_amount} -gt ${assets[${selection_arr[0]}]} ]]; then
                        println ERROR "${FG_RED}ERROR${NC}: you cant send more assets than available on address!" && continue
                      elif [[ ${asset_amount} -eq ${assets[${selection_arr[0]}]} ]]; then
                        unset assets_left[${selection_arr[0]}]
                      else
                        assets_left[${selection_arr[0]}]=$(( assets_left[${selection_arr[0]}] - asset_amount ))
                      fi
                      assets_to_send[${selection_arr[0]}]=${asset_amount}
                      unset assets_on_addr["${selected_value}"]
                      [[ $((++asset_cnt)) -eq ${#assets[@]} ]] && break
                      println DEBUG "Add more assets?"
                      select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                      case $? in
                        0) break ;;
                        1) : ;;
                        2) continue 2 ;;
                      esac
                    done 
                    ;;
                  2) continue ;;
                esac
                echo
              fi

              # Destination
              d_wallet=""
              println DEBUG "# Select ${FG_YELLOW}destination${NC} type"
              select_opt "[w] Wallet" "[a] Address" "[Esc] Cancel"
              case $? in
                0) selectWallet "balance"
                  case $? in
                    1) waitForInput; continue ;;
                    2) continue ;;
                  esac
                  d_wallet="${wallet_name}"
                  getBaseAddress ${d_wallet}
                  getPayAddress ${d_wallet}
                  if [[ -n "${base_addr}" && "${base_addr}" != "${s_addr}" && -n "${pay_addr}" && "${pay_addr}" != "${s_addr}" ]]; then
                    # Both base and enterprise address available, let user choose what to use
                    select_opt "[b] Base (default)" "[e] Enterprise" "[Esc] Cancel"
                    case $? in
                      0) d_addr="${base_addr}" ;;
                      1) d_addr="${pay_addr}" ;;
                      2) continue ;;
                    esac
                  elif [[ -n "${base_addr}" && "${base_addr}" != "${s_addr}" ]]; then
                    d_addr="${base_addr}"
                  elif [[ -n "${pay_addr}" && "${pay_addr}" != "${s_addr}" ]]; then
                    d_addr="${pay_addr}"
                  elif [[ "${base_addr}" = "${s_addr}" || "${pay_addr}" = "${s_addr}" ]]; then
                    println ERROR "\n${FG_RED}ERROR${NC}: sending to same address as source not supported"
                    waitForInput && continue
                  else
                    println ERROR "\n${FG_RED}ERROR${NC}: no address found for wallet ${FG_GREEN}${d_wallet}${NC} :("
                    waitForInput && continue
                  fi
                  ;;
                1) getAnswerAnyCust d_addr "Address" ;;
                2) continue ;;
              esac
              # Destination could be empty, if so without getting a valid address
              if [[ -z ${d_addr} ]]; then
                println ERROR "${FG_RED}ERROR${NC}: destination address field empty"
                waitForInput && continue
              fi

              # Optional metadata/message
              println "\n# Add a message to the transaction?"
              select_opt "[n] No" "[y] Yes"
              case $? in
                0)  unset metafile ;;
                1)  metafile="${TMP_DIR}/metadata_$(date '+%Y%m%d%H%M%S').json"
                    DEFAULTEDITOR="$(command -v nano &>/dev/null && echo 'nano' || echo 'vi')"
                    println OFF "\nA maximum of 64 characters(bytes) is allowed per line."
                    println OFF "${FG_YELLOW}Please don't change default file path when saving.${NC}"
                    exec >&6 2>&7 # normal stdout/stderr
                    waitForInput "press any key to open '${FG_LGRAY}${DEFAULTEDITOR}${NC}' text editor"
                    ${DEFAULTEDITOR} "${metafile}"
                    exec >&8 2>&9 # custom stdout/stderr
                    if [[ ! -f "${metafile}" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: file not found"
                      println ERROR "File: ${FG_LGRAY}${metafile}${NC}"
                      waitForInput && continue
                    fi
                    tput cuu 4 && tput ed
                    if [[ ! -s ${metafile} ]]; then
                      println "Message empty, skip and continue with transaction without message? No to abort!"
                      select_opt "[y] Yes" "[n] No"
                      case $? in
                        0) unset metafile ;;
                        1) continue ;;
                      esac
                    else
                      tx_msg='{"674":{"msg":[]}}'
                      error=""
                      while IFS="" read -r line || [[ -n "${line}" ]]; do
                        line_bytes=$(echo -n "${line}" | wc -c)
                        if [[ ${line_bytes} -gt 64 ]]; then
                          error="${FG_RED}ERROR${NC}: line contains more that 64 bytes(characters) [${line_bytes}]\nLine: ${FG_LGRAY}${line}${NC}" && break
                        fi
                        if ! tx_msg=$(jq -er ".\"674\".msg += [\"${line}\"]" <<< "${tx_msg}" 2>&1); then
                          error="${FG_RED}ERROR${NC}: ${tx_msg}" && break
                        fi
                      done < "${metafile}"
                      [[ -n ${error} ]] && println ERROR "${error}" && waitForInput && continue
                      jq -c . <<< "${tx_msg}" > "${metafile}"
                      jq -r . "${metafile}" >&3 && echo
                      println LOG "Transaction message: ${tx_msg}"
                    fi
                    ;;
              esac

              if ! sendAssets; then
                waitForInput && continue
              fi
              echo
              if ! verifyTx ${s_addr}; then waitForInput && continue; fi
              s_balance=${assets[lovelace]}
              getBalance ${d_addr}
              d_balance=${assets[lovelace]}
              getPayAddress ${s_wallet}
              [[ "${pay_addr}" = "${s_addr}" ]] && s_wallet_type=" (Enterprise)" || s_wallet_type=""
              getPayAddress ${d_wallet}
              [[ "${pay_addr}" = "${d_addr}" ]] && d_wallet_type=" (Enterprise)" || d_wallet_type=""
              echo
              println "Transaction"
              println "  From          : ${FG_GREEN}${s_wallet}${NC}${s_wallet_type}"
              println "  Amount        : ${FG_LBLUE}$(formatLovelace ${amount_lovelace})${NC} Ada"
              for idx in "${!assets_to_send[@]}"; do
                [[ ${idx} = "lovelace" ]] && continue
                println "                  ${FG_LBLUE}$(formatAsset ${assets_to_send[${idx}]})${NC} ${FG_LGRAY}${idx}${NC}"
              done
              if [[ -n "${d_wallet}" ]]; then
                println "  To            : ${FG_GREEN}${d_wallet}${NC}${d_wallet_type}"
              else
                println "  To            : ${FG_LGRAY}${d_addr}${NC}"
              fi
              println "  Fees          : ${FG_LBLUE}$(formatLovelace ${min_fee})${NC} Ada"
              println "  Balance"
              println "  - Source      : ${FG_LBLUE}$(formatLovelace ${s_balance})${NC} Ada"
              println "  - Destination : ${FG_LBLUE}$(formatLovelace ${d_balance})${NC} Ada"
              waitForInput && continue
              ;; ###################################################################
            delegate)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> FUNDS >> DELEGATE"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitForInput && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "# Select wallet to delegate"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "delegate" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
                esac
              else
                selectWallet "delegate" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              getBaseAddress ${wallet_name}
              getBalance ${base_addr}
              if [[ ${assets[lovelace]} -gt 0 ]]; then
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} Ada" "Funds in wallet:"  "$(formatLovelace ${assets[lovelace]})")"
                fi
              else
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                waitForInput && continue
              fi
              getRewards ${wallet_name}

              if [[ ${reward_lovelace} -eq -1 ]]; then
                if [[ ${op_mode} = "online" ]]; then
                  if ! registerStakeWallet ${wallet_name}; then waitForInput && continue; fi
                else
                  println ERROR "\n${FG_YELLOW}The wallet is not a registered wallet on chain and CNTools run in hybrid mode${NC}"
                  println ERROR "Please first register the wallet using 'Wallet >> Register'"
                  waitForInput && continue
                fi
              fi
              echo
              println DEBUG "Do you want to delegate to a local CNTools pool or specify the pool ID?"
              select_opt "[p] CNTools Pool" "[i] Pool ID" "[Esc] Cancel"
              case $? in
                0) selectPool "reg" "${POOL_COLDKEY_VK_FILENAME}"
                  case $? in
                    1) waitForInput; continue ;;
                    2) continue ;;
                  esac
                  getPoolID "${pool_name}"
                  ;;
                1) getAnswerAnyCust pool_id "Pool ID (blank to cancel)"
                  [[ -z "${pool_id}" ]] && continue
                  pool_name="${pool_id}"
                  ;;
                2) continue ;;
              esac
              stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
              pool_delegcert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DELEGCERT_FILENAME}"
              println ACTION "${CCLI} stake-address delegation-certificate --stake-verification-key-file ${stake_vk_file} --stake-pool-id ${pool_id} --out-file ${pool_delegcert_file}"
              ${CCLI} stake-address delegation-certificate --stake-verification-key-file "${stake_vk_file}" --stake-pool-id "${pool_id}" --out-file "${pool_delegcert_file}"
              if ! delegate; then
                if [[ ${op_mode} = "online" ]]; then
                  echo && println ERROR "${FG_RED}ERROR${NC}: failure during delegation, removing newly created delegation certificate file"
                  rm -f "${pool_delegcert_file}"
                fi
                waitForInput && continue
              fi
              echo
              if ! verifyTx ${base_addr}; then waitForInput && continue; fi
              echo
              println "Delegation successfully registered"
              println "Wallet : ${FG_GREEN}${wallet_name}${NC}"
              println "Pool   : ${FG_GREEN}${pool_name}${NC}"
              println "Amount : ${FG_LBLUE}$(formatLovelace ${assets[lovelace]})${NC} Ada"
              waitForInput && continue
              ;; ###################################################################
            withdrawrewards)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> FUNDS >> WITHDRAW REWARDS"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitForInput && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "# Select wallet to withdraw funds from"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "reward" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
                esac
              else
                selectWallet "reward" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              echo
              getBaseAddress ${wallet_name}
              getBalance ${base_addr}
              getRewards ${wallet_name}
              if [[ ${reward_lovelace} -le 0 ]]; then
                println ERROR "Failed to locate any rewards associated with the chosen wallet, please try another one"
                waitForInput && continue
              elif [[ ${assets[lovelace]} -eq 0 ]]; then
                println ERROR "${FG_YELLOW}WARN${NC}: No funds in base address, please send funds to base address of wallet to cover withdraw transaction fee"
                waitForInput && continue
              fi
              println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} Ada" "Funds"  "$(formatLovelace ${assets[lovelace]})")"
              println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} Ada" "Rewards"  "$(formatLovelace ${reward_lovelace})")"
              if ! withdrawRewards; then
                waitForInput && continue
              fi
              echo
              if ! verifyTx ${base_addr}; then waitForInput && continue; fi
              getRewards ${wallet_name}
              echo
              println "Rewards successfully withdrawn"
              println "New Balance"
              println "  Funds   : ${FG_LBLUE}$(formatLovelace ${assets[lovelace]})${NC} Ada"
              println "  Rewards : ${FG_LBLUE}$(formatLovelace ${reward_lovelace})${NC} Ada"
              waitForInput && continue
              ;; ###################################################################
          esac # funds sub OPERATION
        done # Funds loop
        ;; ###################################################################
      pool)
        while true; do # Pool loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> POOL"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Pool Management\n"\
						" ) New      - create a new pool"\
						" ) Import   - import node cold keys from Ledger HW device (only Ledger)"\
						" ) Register - register a newly created pool on chain using a stake wallet (pledge wallet)"\
						" ) Modify   - re-register pool modifying pool definition and/or parameters"\
						" ) Retire   - de-register stake pool from chain in specified epoch"\
						" ) List     - a compact list view of available local pools"\
						" ) Show     - detailed view of specified pool"\
						" ) Rotate   - rotate pool KES keys"\
						" ) Decrypt  - remove write protection and decrypt pool"\
						" ) Encrypt  - encrypt pool cold keys and make all files immutable"\
						" ) Vote     - Cast a CIP-0094 Poll ballot"\
						"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Pool Operation\n"
          select_opt "[n] New" "[i] Import" "[r] Register" "[m] Modify" "[x] Retire" "[l] List" "[s] Show" "[o] Rotate" "[d] Decrypt" "[e] Encrypt" "[v] Vote" "[h] Home"
          case $? in
            0) SUBCOMMAND="new" ;;
            1) SUBCOMMAND="import" ;;
            2) SUBCOMMAND="register" ;;
            3) SUBCOMMAND="modify" ;;
            4) SUBCOMMAND="retire" ;;
            5) SUBCOMMAND="list" ;;
            6) SUBCOMMAND="show" ;;
            7) SUBCOMMAND="rotate" ;;
            8) SUBCOMMAND="decrypt" ;;
            9) SUBCOMMAND="encrypt" ;;
            10) SUBCOMMAND="vote" ;;
            11) break ;;
          esac
          case $SUBCOMMAND in
            new)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> NEW"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              getAnswerAnyCust pool_name "Pool Name"
              # Remove unwanted characters from pool name
              pool_name=${pool_name//[^[:alnum:]]/_}
              if [[ -z "${pool_name}" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: Empty pool name, please retry!"
                waitForInput && continue
              fi
              mkdir -p "${POOL_FOLDER}/${pool_name}"
              pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
              pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
              pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
              pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
              pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
              pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"
              pool_vrf_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_SK_FILENAME}"
              if [[ -f "${pool_hotkey_vk_file}" ]]; then
                println ERROR "${FG_RED}WARN${NC}: A pool ${FG_GREEN}$pool_name${NC} already exists"
                println ERROR "      Choose another name or delete the existing one"
                waitForInput && continue
              fi
              println ACTION "${CCLI} node key-gen-KES --verification-key-file ${pool_hotkey_vk_file} --signing-key-file ${pool_hotkey_sk_file}"
              ${CCLI} node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}"
              if [ -f "${POOL_FOLDER}-pregen/${pool_name}/${POOL_ID_FILENAME}" ]; then
                mv ${POOL_FOLDER}'-pregen/'${pool_name}/* ${POOL_FOLDER}/${pool_name}/
                rm -r ${POOL_FOLDER}'-pregen/'${pool_name}
              else
                println ACTION "${CCLI} node key-gen --cold-verification-key-file ${pool_coldkey_vk_file} --cold-signing-key-file ${pool_coldkey_sk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file}"
                ${CCLI} node key-gen --cold-verification-key-file "${pool_coldkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}"
              fi
              println ACTION "${CCLI} node key-gen-VRF --verification-key-file ${pool_vrf_vk_file} --signing-key-file ${pool_vrf_sk_file}"
              ${CCLI} node key-gen-VRF --verification-key-file "${pool_vrf_vk_file}" --signing-key-file "${pool_vrf_sk_file}"
              chmod 600 "${POOL_FOLDER}/${pool_name}/"*
              getPoolID ${pool_name}
              echo
              println "Pool: ${FG_GREEN}${pool_name}${NC}"
              [[ -n ${pool_id} ]] && println "ID (hex)    : ${pool_id}"
              [[ -n ${pool_id_bech32} ]] && println "ID (bech32) : ${pool_id_bech32}"
              waitForInput && continue
              ;; ###################################################################
           import)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> IMPORT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              getAnswerAnyCust pool_name "Pool Name"
              # Remove unwanted characters from pool name
              pool_name=${pool_name//[^[:alnum:]]/_}
              if [[ -z "${pool_name}" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: Empty pool name, please retry!"
                waitForInput && continue
              fi
              mkdir -p "${POOL_FOLDER}/${pool_name}"
              pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
              pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
              pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
              pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HW_COLDKEY_SK_FILENAME}"
              pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
              pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"
              pool_vrf_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_SK_FILENAME}"
              if [[ -f "${pool_hotkey_vk_file}" ]]; then
                println ERROR "${FG_RED}WARN${NC}: A pool ${FG_GREEN}$pool_name${NC} already exists"
                println ERROR "      Choose another name or delete the existing one"
                waitForInput && continue
              fi

              println ACTION "${CCLI} node key-gen-KES --verification-key-file ${pool_hotkey_vk_file} --signing-key-file ${pool_hotkey_sk_file}"
              ${CCLI} node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}"

              println ACTION "${CCLI} node key-gen-VRF --verification-key-file ${pool_vrf_vk_file} --signing-key-file ${pool_vrf_sk_file}"
              ${CCLI} node key-gen-VRF --verification-key-file "${pool_vrf_vk_file}" --signing-key-file "${pool_vrf_sk_file}"

              println ACTION "cardano-hw-cli node key-gen --path 1853H/1815H/0H/0H --hw-signing-file ${pool_coldkey_sk_file} --cold-verification-key-file ${pool_coldkey_kk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file}"
              if ! unlockHWDevice "export cold pub keys"; then safeDel "${POOL_FOLDER}/${pool_name}"; continue; fi
              cardano-hw-cli node key-gen --path "1853H/1815H/0H/0H" --hw-signing-file "${pool_coldkey_sk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}"
              jq '.description = "Stake Pool Operator Hardware Verification Key"' "${pool_coldkey_vk_file}" > "${TMP_DIR}/$(basename "${pool_coldkey_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${pool_coldkey_vk_file}").tmp" "${pool_coldkey_vk_file}"

              chmod 600 "${POOL_FOLDER}/${pool_name}/"*
              sed -i 's/Shelley//g' "${pool_coldkey_vk_file}" # TEMP FIX FOR https://github.com/vacuumlabs/cardano-hw-cli/issues/139
              getPoolID ${pool_name} && touch "${POOL_FOLDER}/${pool_name}/.hwtype"
              echo
              println "Pool: ${FG_GREEN}${pool_name}${NC}"
              [[ -n ${pool_id} ]] && println "ID (hex)    : ${pool_id}"
              [[ -n ${pool_id_bech32} ]] && println "ID (bech32) : ${pool_id_bech32}"
              waitForInput && continue
              ;; ##################################################################
            register|modify)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> ${SUBCOMMAND^^}"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitForInput && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo

              unset isHWpool
              println DEBUG "# Select pool to register|modify"
              [[ ${SUBCOMMAND} = "register" ]] && pool_filter="non-reg" || pool_filter="reg"
              if [[ ${op_mode} = "online" ]]; then
                selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_VRF_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
                case $? in
                  0) isHWpool=Y ;;
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: signing keys missing from pool!" && waitForInput && continue ;;
                esac
              else
                selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_VRF_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
                [[ $? -eq 0 ]] && isHWpool=Y
              fi
              echo
              pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
              println DEBUG "# Pool Parameters"
              if [[ ${SUBCOMMAND} = "modify" ]]; then
                if [[ ! -f ${pool_config} ]]; then
                  println "${FG_YELLOW}WARN${NC}: Missing pool config file: ${pool_config}"
                  println "Unable to show old values, please re-enter all values to generate a new pool config file"
                else
                  println DEBUG "Old registration values shown as default, press enter to use default value"
                fi
              else
                println DEBUG "press enter to use default value"
              fi
              echo
              pledge_ada=50000 # default pledge
              [[ -f "${pool_config}" ]] && pledge_ada=$(jq -r '.pledgeADA //0' "${pool_config}")
              getAnswerAnyCust pledge_enter "Pledge (in Ada, default: $(formatLovelace $(AdaToLovelace ${pledge_ada}))"
              pledge_enter="${pledge_enter//,}"
              if [[ -n "${pledge_enter}" ]]; then
                if ! AdaToLovelace "${pledge_enter}" >/dev/null; then
                  waitForInput && continue
                fi
                pledge_lovelace=$(AdaToLovelace "${pledge_enter}")
                pledge_ada="${pledge_enter}"
              else
                pledge_lovelace=$(AdaToLovelace "${pledge_ada}")
              fi
              margin=7.5 # default margin in %
              [[ -f "${pool_config}" ]] && margin=$(jq -r '.margin //0' "${pool_config}")
              getAnswerAnyCust margin_enter "Margin (in %, default: ${margin})"
              if [[ -n "${margin_enter}" ]]; then
                if ! pctToFraction "${margin_enter}" >/dev/null; then
                  waitForInput && continue
                fi
                margin_fraction=$(pctToFraction "${margin_enter}")
                margin="${margin_enter}"
              else
                margin_fraction=$(pctToFraction "${margin}")
              fi
              minPoolCost=$(formatLovelace $(jq -r '.minPoolCost //0' <<< "${PROT_PARAMS}") normal) # convert to Ada
              [[ -f ${pool_config} ]] && cost_ada=$(jq -r '.costADA //0' "${pool_config}") || cost_ada=${minPoolCost} # default cost
              [[ $(bc -l <<< "${cost_ada} < ${minPoolCost}") -eq 1 ]] && cost_ada=${minPoolCost} # raise old value to new minimum cost
              getAnswerAnyCust cost_enter "Cost (in Ada, minimum: ${minPoolCost}, default: ${cost_ada})"
              cost_enter="${cost_enter//,}"
              if [[ -n "${cost_enter}" ]]; then
                if ! AdaToLovelace "${cost_enter}" >/dev/null; then
                  waitForInput && continue
                fi
                cost_lovelace=$(AdaToLovelace "${cost_enter}")
                cost_ada="${cost_enter}"
              else
                cost_lovelace=$(AdaToLovelace "${cost_ada}")
              fi
              if [[ $(bc -l <<< "${cost_ada} < ${minPoolCost}") -eq 1 ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: cost set lower than allowed"
                waitForInput && continue
              fi
              println DEBUG "\n# Pool Metadata\n"
              pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta.json"
              if [[ ! -f "${pool_config}" ]] || ! meta_json_url=$(jq -er .json_url "${pool_config}"); then meta_json_url="https://foo.bat/poolmeta.json"; fi
              getAnswerAnyCust json_url_enter "Enter Pool's JSON URL to host metadata file - URL length should be less than 64 chars (default: ${meta_json_url})"
              [[ -n "${json_url_enter}" ]] && meta_json_url="${json_url_enter}"
              if [[ ! "${meta_json_url}" =~ https?://.* || ${#meta_json_url} -gt 64 ]]; then
                println ERROR "${FG_RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
                waitForInput && continue
              fi
              metadata_done=false
              meta_tmp="${TMP_DIR}/url_poolmeta.json"
              if curl -sL -f -m ${CURL_TIMEOUT} -o "${meta_tmp}" ${meta_json_url} && jq -er . "${meta_tmp}" &>/dev/null; then
                [[ $(wc -c <"${meta_tmp}") -gt 512 ]] && println ERROR "${FG_RED}ERROR${NC}: file at specified URL contain more than allowed 512b of data!" && waitForInput && continue
                echo && jq -r . "${meta_tmp}" >&3 && echo
                if ! jq -er .name "${meta_tmp}" &>/dev/null; then println ERROR "${FG_RED}ERROR${NC}: unable to get 'name' field from downloaded metadata file!" && waitForInput && continue; fi
                if ! jq -er .ticker "${meta_tmp}" &>/dev/null; then println ERROR "${FG_RED}ERROR${NC}: unable to get 'ticker' field from downloaded metadata file!" && waitForInput && continue; fi
                if ! jq -er .homepage "${meta_tmp}" &>/dev/null; then println ERROR "${FG_RED}ERROR${NC}: unable to get 'homepage' field from downloaded metadata file!" && waitForInput && continue; fi
                if ! jq -er .description "${meta_tmp}" &>/dev/null; then println ERROR "${FG_RED}ERROR${NC}: unable to get 'description' field from downloaded metadata file!" && waitForInput && continue; fi
                println DEBUG "Metadata exists at URL.  Use existing data?"
                select_opt "[y] Yes" "[n] No"
                case $? in
                  0) mv "${meta_tmp}" "${pool_meta_file}"
                    metadata_done=true
                    ;;
                  1) rm -f "${meta_tmp}" ;; # clean up temp file
                esac
              fi
              if [[ ${metadata_done} = false ]]; then
                echo
                if [[ ! -f "${pool_meta_file}" ]] || ! meta_name=$(jq -er .name "${pool_meta_file}"); then meta_name="${pool_name}"; fi
                if [[ ! -f "${pool_meta_file}" ]] || ! meta_ticker=$(jq -er .ticker "${pool_meta_file}"); then meta_ticker="$(echo ${pool_name//[^[:alnum:]]/} | tr '[:lower:]' '[:upper:]' | cut -c-5)"; fi
                if [[ ! -f "${pool_meta_file}" ]] || ! meta_description=$(jq -er .description "${pool_meta_file}"); then meta_description="No Description"; fi
                if [[ ! -f "${pool_meta_file}" ]] || ! meta_homepage=$(jq -er .homepage "${pool_meta_file}"); then meta_homepage="https://foo.com"; fi
                if [[ ! -f "${pool_meta_file}" ]] || ! meta_extended=$(jq -er .extended "${pool_meta_file}"); then meta_extended="https://foo.com/metadata/extended.json"; fi
                getAnswerAnyCust name_enter "Enter Pool's Name (default: ${meta_name})"
                [[ -n "${name_enter}" ]] && meta_name="${name_enter}"
                if [[ ${#meta_name} -gt 50 ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: Name cannot exceed 50 characters"
                  waitForInput && continue
                fi
                getAnswerAnyCust ticker_enter "Enter Pool's Ticker , should be between 3-5 characters (default: ${meta_ticker})"
                ticker_enter=${ticker_enter//[^[:alnum:]]/}
                [[ -n "${ticker_enter}" ]] && meta_ticker="${ticker_enter^^}"
                if [[ ${#meta_ticker} -lt 3 || ${#meta_ticker} -gt 5 ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: ticker must be between 3-5 characters"
                  waitForInput && continue
                fi
                getAnswerAnyCust desc_enter "Enter Pool's Description (default: ${meta_description})"
                [[ -n "${desc_enter}" ]] && meta_description="${desc_enter}"
                if [[ ${#meta_description} -gt 255 ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: Description cannot exceed 255 characters"
                  waitForInput && continue
                fi
                getAnswerAnyCust homepage_enter "Enter Pool's Homepage (default: ${meta_homepage})"
                [[ -n "${homepage_enter}" ]] && meta_homepage="${homepage_enter}"
                if [[ ! "${meta_homepage}" =~ https?://.* || ${#meta_homepage} -gt 64 ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
                  waitForInput && continue
                fi
                println DEBUG "\nOptionally set an extended metadata URL?"
                select_opt "[n] No" "[y] Yes"
                case $? in
                  0) meta_extended_option=""
                    ;;
                  1) getAnswerAnyCust extended_enter "Enter URL to extended metadata (default: ${meta_extended})"
                    [[ -n "${extended_enter}" ]] && meta_extended="${extended_enter}"
                    if [[ ! "${meta_extended}" =~ https?://.* || ${#meta_extended} -gt 64 ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: invalid extended URL format or more than 64 chars in length"
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
                  println ERROR "\n${FG_RED}ERROR${NC}: Total metadata size cannot exceed 512 chars in length, current length: ${metadata_size}"
                  waitForInput && continue
                else
                  cp -f "${new_pool_meta_file}" "${pool_meta_file}"
                fi
                println DEBUG "\n${FG_YELLOW}Please host file ${pool_meta_file} as-is at ${meta_json_url}${NC}"
                waitForInput "Press any key to proceed with registration after metadata file is uploaded"
              fi
              relay_output=""
              relay_array=()
              println DEBUG "\n# Pool Relay Registration"
              if [[ -f "${pool_config}" && $(jq '.relays | length' "${pool_config}") -gt 0 ]]; then
                println DEBUG "\nPrevious relay configuration:\n"
                jq -r '["TYPE","ADDRESS","PORT"], (.relays[] | [.type //"-",.address //"-",.port //"-"]) | @tsv' "${pool_config}" | column -t >&3
                println DEBUG "\nReuse previous relay configuration?"
                select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
                case $? in
                  0) while read -r type address port; do
                      relay_array+=( "type" "${type}" "address" "${address}" "port" "${port}" )
                      if [[ ${type} = "DNS_A" ]]; then
                        relay_output+="--single-host-pool-relay ${address} --pool-relay-port ${port} "
                      elif [[ ${type} = "IPv4" ]]; then
                        relay_output+="--pool-relay-port ${port} --pool-relay-ipv4 ${address} "
                      elif [[ ${type} = "IPv6" ]]; then
                        relay_output+="--pool-relay-port ${port} --pool-relay-ipv6 ${address} "                      
		      elif [[ ${type} = "DNS_SRV" ]]; then
                        relay_output+="--multi-host-pool-relay ${address} "
                      fi
                    done< <(jq -r '.relays[] | "\(.type) \(.address) \(.port)"' "${pool_config}")
                    ;;
                  1) : ;; # Do nothing
                  2) continue ;;
                esac
              fi
              if [[ -z ${relay_output} ]]; then
                while true; do
                  select_opt "[d] A or AAAA DNS record" "[i] IPv4/v6 address" "[s] SRV DNS record" "[Esc] Cancel"
                  case $? in
                    0) getAnswerAnyCust relay_dns_a_enter "Enter relays's DNS record, only A or AAAA DNS records"
                      if [[ -z "${relay_dns_a_enter}" ]]; then
                        println ERROR "${FG_RED}ERROR${NC}: DNS record can not be empty!"
                      else
                        getAnswerAnyCust relay_port_enter "Enter relays's port"
                        if [[ -n "${relay_port_enter}" ]]; then
                          if ! isNumber ${relay_port_enter} || [[ ${relay_port_enter} -lt 1 || ${relay_port_enter} -gt 65535 ]]; then
                            println ERROR "${FG_RED}ERROR${NC}: invalid port number!"
                          else
                            relay_array+=( "type" "DNS_A" "address" "${relay_dns_a_enter}" "port" "${relay_port_enter}" )
                            relay_output+="--single-host-pool-relay ${relay_dns_a_enter} --pool-relay-port ${relay_port_enter} "
                          fi
                        else
                          println ERROR "${FG_RED}ERROR${NC}: Port can not be empty!"
                        fi
                      fi
                      ;;
                    1) getAnswerAnyCust relay_ip_enter "Enter relays's IPv4/v6 address"
                      if [[ -n "${relay_ip_enter}" ]]; then
                        if ! isValidIPv4 "${relay_ip_enter}" && ! isValidIPv6 "${relay_ip_enter}"; then
                          println ERROR "${FG_RED}ERROR${NC}: invalid IPv4/v6 address format!"
                        else
                          getAnswerAnyCust relay_port_enter "Enter relays's port"
                          if [[ -n "${relay_port_enter}" ]]; then
                            if ! isNumber ${relay_port_enter} || [[ ${relay_port_enter} -lt 1 || ${relay_port_enter} -gt 65535 ]]; then
                              println ERROR "${FG_RED}ERROR${NC}: invalid port number!"
                            elif isValidIPv4 "${relay_ip_enter}"; then
                              relay_array+=( "type" "IPv4" "address" "${relay_ip_enter}" "port" "${relay_port_enter}" )
                              relay_output+="--pool-relay-port ${relay_port_enter} --pool-relay-ipv4 ${relay_ip_enter} "
                            else
                              relay_array+=( "type" "IPv6" "address" "${relay_ip_enter}" "port" "${relay_port_enter}" )
                              relay_output+="--pool-relay-port ${relay_port_enter} --pool-relay-ipv6 ${relay_ip_enter} "
                            fi
                          else
                            println ERROR "${FG_RED}ERROR${NC}: Port can not be empty!"
                          fi
                        fi
                      else
                        println ERROR "${FG_RED}ERROR${NC}: IPv4/v6 address empty!"
                      fi
                      ;;
                    2) getAnswerAnyCust relay_dns_srv_enter "Enter relays's DNS record, only SRV records"
                      if [[ -z "${relay_dns_srv_enter}" ]]; then
                        println ERROR "${FG_RED}ERROR${NC}: DNS record can not be empty!"
                      else
                        relay_array+=( "type" "DNS_SRV" "address" "${relay_dns_srv_enter}" "port" "" )
                        relay_output+="--multi-host-pool-relay ${relay_dns_srv_enter} "
                      fi
                      ;;		    
                    3) continue 2 ;;
                  esac
                  println DEBUG "Add more relay entries?"
                  select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                  case $? in
                    0) break ;;
                    1) continue ;;
                    2) continue 2 ;;
                  esac
                done
              fi
              echo

              owner_wallets=()
              reward_wallet=""
              hw_reward_wallet='N'
              hw_owner_wallets='N'
              reuse_wallets='N'
              # Old owner/reward wallets
              if [[ -f ${pool_config} ]]; then

                println DEBUG "# Previous Owner(s)/Reward wallets"
                if jq -er '.pledgeWallet' "${pool_config}" &>/dev/null; then # legacy support
                  owner_wallets+=( "$(jq -r '.pledgeWallet' "${pool_config}")" )
                  println DEBUG "Owner wallet #1 : ${FG_GREEN}${owner_wallets[0]}${NC}"
                else
                  for owner in $(jq -c '.owners[]' "${pool_config}"); do
                    wallet_name=$(jq -r '.wallet_name' <<< "${owner}")
                    owner_wallets+=( "${wallet_name}" )
                    println DEBUG "Owner wallet #$(jq -r '.id' <<< "${owner}") : ${FG_GREEN}${wallet_name}${NC}"
                  done
                fi

                reward_wallet=$(jq -r '.rewardWallet //empty' "${pool_config}")
                println DEBUG "Reward wallet   : ${FG_GREEN}${reward_wallet}${NC}"
                println DEBUG "\nReuse previous Owner(s)/Reward wallets?"
                select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
                case $? in
                  0) reuse_wallets='Y'
                    for wallet_name in "${owner_wallets[@]}"; do # Validate each wallet that they still exist and contain the correct keys
                      getWalletType ${wallet_name}
                      case $? in
                        0) if [[ ${wallet_name} = "${owner_wallets[0]}" ]]; then # main owner, must be a CLI wallet
                              println ERROR "${FG_RED}ERROR${NC}: main/first pool owner can NOT be a hardware wallet!"
                              println ERROR "Use a CLI wallet as owner with enough funds to pay for pool deposit and registration transaction fee"
                              println ERROR "Add the hardware wallet as an additional multi-owner to the pool later in the pool registration wizard"
                              waitForInput "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N' && break
                            else hw_owner_wallets='Y'; fi ;;
                        2) if [[ ${op_mode} = "online" ]]; then
                              println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted for wallet ${FG_GREEN}${wallet_name}${NC}, please decrypt before use!"
                              waitForInput && continue 2
                            fi ;;
                        3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                            waitForInput "Did you mean to run in Hybrid mode?  press any key to return home!" && continue 2 ;;
                        4) if [[ ${wallet_name} != "${owner_wallets[0]}" && ! -f "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ]]; then # ignore if payment vkey is missing for multi-owner, only stake vkey important
                              println ERROR "${FG_RED}ERROR${NC}: stake verification key missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                              waitForInput "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N' && break
                            fi ;;
                      esac
                      if [[ ${wallet_name} = "${owner_wallets[0]}" ]] && ! isWalletRegistered ${wallet_name}; then # make sure at least main owner is registered
                        if [[ ${op_mode} = "hybrid" ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not a registered wallet on chain and CNTools run in hybrid mode"
                          println ERROR "Please first register main owner wallet to use in pool registration using 'Wallet >> Register'"
                          waitForInput && continue 2
                        fi
                        getBaseAddress ${wallet_name}
                        getBalance ${base_addr}
                        if [[ ${assets[lovelace]} -eq 0 ]]; then
                          println ERROR "${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}, needed to pay for registration fee"
                          waitForInput && continue 2
                        fi
                        println DEBUG "# Wallet Registration Transaction"
                        if ! registerStakeWallet ${wallet_name}; then waitForInput && continue 2; fi
                      fi
                    done

                    if [[ ${reuse_wallets} = 'Y' ]]; then # re-check reuse_wallets in case flow was broken
                      getWalletType ${reward_wallet}
                      case $? in
                        0) hw_reward_wallet='Y' ;;
                        4) if [[ ! -f "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ]]; then # ignore if payment vkey is missing for reward wallet, only stake vkey important
                              println ERROR "${FG_RED}ERROR${NC}: stake verification key missing from reward wallet ${FG_GREEN}${wallet_name}${NC}!"
                              waitForInput "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N'
                            fi ;;
                      esac
                    fi

                    ;;
                  1) owner_wallets=() && reward_wallet="" && reuse_wallets='N'
                    println DEBUG "\n${FG_YELLOW}If new wallets are chosen for owner(s)/reward, a manual delegation to the pool for each wallet is needed if not done already!${NC}\n"
                    ;;
                  2) continue ;;
                esac
              fi

              if [[ ${reuse_wallets} = 'N' ]]; then
                println DEBUG "# Select main ${FG_YELLOW}owner/pledge${NC} wallet (normal CLI wallet)"
                if [[ ${op_mode} = "online" ]]; then
                  if ! selectWallet "delegate" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
                    [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
                  fi
                  getWalletType ${wallet_name}
                  case $? in
                    0) println ERROR "${FG_RED}ERROR${NC}: main pool owner can NOT be a hardware wallet!"
                      println ERROR "Use a CLI wallet as owner with enough funds to pay for pool deposit and registration transaction fee"
                      println ERROR "Add the hardware wallet as an additional multi-owner to the pool later in the pool registration wizard"
                      waitForInput && continue ;;
                    2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                    3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
                  esac
                else
                  selectWallet "delegate" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"
                  case $? in
                    1) waitForInput; continue ;;
                    2) continue ;;
                  esac
                  getWalletType ${wallet_name}
                fi
                if ! isWalletRegistered ${wallet_name}; then
                  if [[ ${op_mode} = "hybrid" ]]; then
                    println ERROR "\n${FG_RED}ERROR${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not a registered wallet on chain and CNTools run in hybrid mode"
                    println ERROR "Please first register the main CLI wallet to use in pool registration using 'Wallet >> Register'"
                    waitForInput && continue
                  fi
                  getBaseAddress ${wallet_name}
                  getBalance ${base_addr}
                  if [[ ${assets[lovelace]} -eq 0 ]]; then
                    println ERROR "${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}, needed to pay for registration fee"
                    waitForInput && continue
                  fi
                  println DEBUG "# Wallet Registration Transaction"
                  if ! registerStakeWallet ${wallet_name}; then waitForInput && continue; fi
                fi
                owner_wallets+=( "${wallet_name}" )
                println DEBUG "Owner #1 : ${FG_GREEN}${wallet_name}${NC} added!"
              fi

              getBaseAddress ${owner_wallets[0]}
              getBalance ${base_addr}
              if [[ ${assets[lovelace]} -eq 0 ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available in owner wallet ${FG_GREEN}${owner_wallets[0]}${NC}"
                waitForInput && continue
              fi

              if [[ ${reuse_wallets} = 'N' ]]; then
                println DEBUG "\nRegister a multi-owner pool (you need to have stake.vkey of any additional owner in a seperate wallet folder under $CNODE_HOME/priv/wallet)?"
                while true; do
                  select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                  case $? in
                    0) break ;;
                    1) if selectWallet "delegate" "${WALLET_STAKE_VK_FILENAME}" "${owner_wallets[@]}"; then # ${wallet_name} populated by selectWallet function
                        getWalletType ${wallet_name}
                        case $? in
                          0) hw_owner_wallets='Y' ;;
                          2) if [[ ${op_mode} = "online" ]]; then
                                println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted for wallet ${FG_GREEN}${wallet_name}${NC}, please decrypt before use!"
                                waitForInput && continue 2
                              fi ;;
                          3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                              waitForInput "Did you mean to run in Hybrid mode?  press any key to return home!" && continue 2 ;;
                          4) if [[ ! -f "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ]]; then # ignore if payment vkey is missing
                                println ERROR "${FG_RED}ERROR${NC}: stake verification key missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                                println DEBUG "Add another owner?" && continue 
                              fi ;;
                        esac
                      else
                        println DEBUG "Add more owners?" && continue
                      fi
                      owner_wallets+=( "${wallet_name}" )
                      println DEBUG "Owner #${#owner_wallets[@]} : ${FG_GREEN}${wallet_name}${NC} added!"
                      ;;
                    2) continue 2 ;;
                  esac
                  println DEBUG "Add more owners?"
                done
              fi

              if [[ ${reuse_wallets} = 'N' ]]; then
                println DEBUG "\nUse a separate rewards wallet from main owner?"
                select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                case $? in
                  0) reward_wallet="${owner_wallets[0]}" ;;
                  1) if ! selectWallet "none" "${WALLET_STAKE_VK_FILENAME}" "${owner_wallets[0]}"; then # ${wallet_name} populated by selectWallet function
                      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
                    fi
                    reward_wallet="${wallet_name}"
                    getWalletType ${reward_wallet}
                    case $? in
                      0) hw_reward_wallet='Y' ;;
                      4) if [[ ! -f "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ]]; then # ignore if payment vkey is missing
                            println ERROR "${FG_RED}ERROR${NC}: stake verification key missing from wallet ${FG_GREEN}${wallet_name}${NC}!" && waitForInput && continue
                          fi ;;
                    esac
                    ;;
                  2) continue ;;
                esac
              fi

              multi_owner_output=""
              for wallet_name in "${owner_wallets[@]}"; do
                [[ "${wallet_name}" = "${owner_wallets[0]}" ]] && continue # skip main owner
                multi_owner_output+="--pool-owner-stake-verification-key-file ${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME} "
              done

              owner_payment_sk_file="${WALLET_FOLDER}/${owner_wallets[0]}/${WALLET_PAY_SK_FILENAME}"
              owner_payment_vk_file="${WALLET_FOLDER}/${owner_wallets[0]}/${WALLET_PAY_VK_FILENAME}"
              owner_stake_vk_file="${WALLET_FOLDER}/${owner_wallets[0]}/${WALLET_STAKE_VK_FILENAME}"
              owner_stake_sk_file="${WALLET_FOLDER}/${owner_wallets[0]}/${WALLET_STAKE_SK_FILENAME}"
              owner_delegation_cert_file="${WALLET_FOLDER}/${owner_wallets[0]}/${WALLET_DELEGCERT_FILENAME}"
              reward_stake_vk_file="${WALLET_FOLDER}/${reward_wallet}/${WALLET_STAKE_VK_FILENAME}"

              pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
              pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
              #pool_coldkey_vk_file set by getPoolType at start
              #pool_coldkey_sk_file set by getPoolType at start
              pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"
              pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
              pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"
              pool_saved_kes_start="${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}"
              pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"
              pool_deregcert_file="${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}"

              # Make a backup of current reg cert if available
              [[ -f "${pool_regcert_file}" ]] && cp -f "${pool_regcert_file}" "${pool_regcert_file}.tmp"

              if [[ ${SUBCOMMAND} = "register" ]]; then
                if [[ ${op_mode} = "online" ]]; then
                  current_kes_period=$(getCurrentKESperiod)
                  echo "${current_kes_period}" > ${pool_saved_kes_start}

                  if [[ ! -f "${pool_opcert_file}" ]]; then
                    if [[ ${isHWpool} = 'Y' ]]; then
                      if ! unlockHWDevice "issue the opcert"; then return 1; fi
                        println ACTION "cardano-hw-cli node issue-op-cert --kes-verification-key-file ${pool_hotkey_vk_file} --hw-signing-file ${pool_coldkey_sk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file} --kes-period ${current_kes_period} --out-file ${pool_opcert_file}"
                        ! cardano-hw-cli node issue-op-cert \
                          --kes-verification-key-file "${pool_hotkey_vk_file}" \
                          --hw-signing-file "${pool_coldkey_sk_file}" \
                          --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" \
                          --kes-period "${current_kes_period}" \
                          --out-file "${pool_opcert_file}" \
                        && return 1
                    else
                      println ACTION "${CCLI} node issue-op-cert --kes-verification-key-file ${pool_hotkey_vk_file} --cold-signing-key-file ${pool_coldkey_sk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file} --kes-period ${current_kes_period} --out-file ${pool_opcert_file}"
                      ${CCLI} node issue-op-cert --kes-verification-key-file "${pool_hotkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" --kes-period "${current_kes_period}" --out-file "${pool_opcert_file}"
                    fi
                  fi

                elif [[ ! -f ${pool_hotkey_vk_file} || ! -f ${pool_hotkey_sk_file} || ! -f ${pool_opcert_file} ]]; then
                  println DEBUG "\n${FG_YELLOW}Pool operational certificate not generated in hybrid mode,"
                  println DEBUG "please use 'Pool >> Rotate' in offline mode to generate new hot keys, op cert and KES start period and transfer to online node!${NC}"
                  println DEBUG "Files generated when running 'Pool >> Rotate' to be transferred:"
                  println DEBUG "${FG_LGRAY}${pool_hotkey_vk_file}${NC}"
                  println DEBUG "${FG_LGRAY}${pool_hotkey_sk_file}${NC}"
                  println DEBUG "${FG_LGRAY}${pool_opcert_file}${NC}"
                  println DEBUG "${FG_LGRAY}${pool_saved_kes_start}${NC}"
                  waitForInput "press any key to continue"
                fi
              fi

              println LOG "creating registration certificate"
              println ACTION "${CCLI} stake-pool registration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --vrf-verification-key-file ${pool_vrf_vk_file} --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file ${reward_stake_vk_file} --pool-owner-stake-verification-key-file ${owner_stake_vk_file} ${multi_owner_output} --metadata-url ${meta_json_url} --metadata-hash \$\(${CCLI} stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} \) ${relay_output} ${NETWORK_IDENTIFIER} --out-file ${pool_regcert_file}"
              ${CCLI} stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${reward_stake_vk_file}" --pool-owner-stake-verification-key-file "${owner_stake_vk_file}" ${multi_owner_output} --metadata-url "${meta_json_url}" --metadata-hash "$(${CCLI} stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} )" ${relay_output} ${NETWORK_IDENTIFIER} --out-file "${pool_regcert_file}"

              delegate_owner_wallet='N'
              if [[ ${SUBCOMMAND} = "register" ]]; then
                if [[ ${hw_owner_wallets} = 'Y' || ${hw_reward_wallet} = 'Y' || ${isHWpool} = 'Y' ]]; then
                  println DEBUG "\n${FG_BLUE}INFO${NC}: hardware wallet included as reward or multi-owner or hardware pool, automatic owner/reward wallet delegation disabled"
                  println DEBUG "${FG_BLUE}INFO${NC}: ${FG_YELLOW}please manually delegate all wallets to the pool!!!${NC}"
                  waitForInput "press any key to continue"
                else
                  println LOG "creating delegation certificate for main owner wallet"
                  println ACTION "${CCLI} stake-address delegation-certificate --stake-verification-key-file ${owner_stake_vk_file} --cold-verification-key-file ${pool_coldkey_vk_file} --out-file ${owner_delegation_cert_file}"
                  ${CCLI} stake-address delegation-certificate --stake-verification-key-file "${owner_stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${owner_delegation_cert_file}"
                  delegate_owner_wallet='Y'
                  if [[ "${owner_wallets[0]}" != "${reward_wallet}" ]]; then
                    println DEBUG "\n${FG_BLUE}INFO${NC}: reward wallet not the same as owner, automatic reward wallet delegation disabled"
                    println DEBUG "${FG_BLUE}INFO${NC}: ${FG_YELLOW}please manually delegate reward wallet to the pool!!!${NC}"
                    waitForInput "press any key to continue"
                  fi
                fi
              fi

              if [[ ${SUBCOMMAND} = "register" ]]; then
                println DEBUG "\n# Pool Registration Transaction"
                registerPool
                rc=$?
              else
                println DEBUG "\n# Pool Update Transaction"
                modifyPool
                rc=$?
              fi

              if [[ $rc -eq 0 ]]; then
                [[ -f "${pool_regcert_file}.tmp" ]] && rm -f "${pool_regcert_file}.tmp" # remove backup of old reg cert if it exist (modify)
                [[ -f "${pool_deregcert_file}" ]] && rm -f "${pool_deregcert_file}" # delete de-registration cert if available
              else # rc=1 failed | rc=2 used for offline mode, treat as failed for now, files written on submission
                [[ $rc -eq 1 ]] && echo && println ERROR "\n${FG_RED}ERROR${NC}: failure during pool ${SUBCOMMAND}!"
                if [[ ${SUBCOMMAND} = "register" ]]; then
                  [[ -f "${pool_regcert_file}" ]] && rm -f "${pool_regcert_file}"
                else
                  [[ -f "${pool_regcert_file}.tmp" ]] && mv -f "${pool_regcert_file}.tmp" "${pool_regcert_file}" # restore reg cert backup
                fi
                [[ $rc -eq 1 ]] && waitForInput && continue
              fi

              # Save pool config
              # Construct relay json array
              relay_json=$({
                printf '['
                printf '{"%s":"%s","%s":"%s","%s":"%s"},\n' "${relay_array[@]}" | sed '$s/,$//'
                printf ']'
              } | jq -c .)
              # Construct owner json array
              owner_array=()
              for index in "${!owner_wallets[@]}"; do
                owner_array+=( "$((index+1))" "${owner_wallets[${index}]}" )
              done
              owner_json=$({
                printf '['
                printf '{"id":"%s","wallet_name":"%s"},\n' "${owner_array[@]}" | sed '$s/,$//'
                printf ']'
              } | jq -c .)
              echo "{\"owners\":$owner_json,\"rewardWallet\":\"$reward_wallet\",\"pledgeADA\":\"$pledge_ada\",\"margin\":\"$margin\",\"costADA\":\"$cost_ada\",\"json_url\":\"$meta_json_url\",\"relays\": $relay_json}" > "${pool_config}"
              chmod 600 "${POOL_FOLDER}/${pool_name}/"*
              [[ -f "${pool_deregcert_file}" ]] && rm -f ${pool_deregcert_file} # delete de-registration cert if available
              echo
              if [[ ${op_mode} = "online" ]]; then
                getBaseAddress ${owner_wallets[0]}
                if ! verifyTx ${base_addr}; then waitForInput && continue; fi
                echo
                if [[ ${SUBCOMMAND} = "register" ]]; then
                  println "Pool ${FG_GREEN}${pool_name}${NC} successfully registered!"
                else
                  println "Pool ${FG_GREEN}${pool_name}${NC} successfully updated!"
                fi
              else
                println "Pool ${FG_GREEN}${pool_name}${NC} built!"
                println "${FG_YELLOW}Follow the steps above to sign and submit transaction!${NC}"
              fi
              for index in "${!owner_wallets[@]}"; do
                println "Owner #$((index+1))      : ${FG_GREEN}${owner_wallets[${index}]}${NC}"
              done
              println "Reward Wallet : ${FG_GREEN}${reward_wallet}${NC}"
              println "Pledge        : ${FG_LBLUE}$(formatLovelace $(AdaToLovelace ${pledge_ada}))${NC} Ada"
              println "Margin        : ${FG_LBLUE}${margin}${NC} %"
              println "Cost          : ${FG_LBLUE}$(formatLovelace ${cost_lovelace})${NC} Ada"
              if [[ ${SUBCOMMAND} = "register" ]]; then
                if [[ ${op_mode} = "hybrid" ]]; then
                  println DEBUG "\n${FG_YELLOW}After offline pool transaction is signed and submitted, uncomment and set value for POOL_NAME in ${PARENT}/env with${NC} '${FG_GREEN}${pool_name}${NC}'"
                else
                  println DEBUG "\n${FG_YELLOW}Uncomment and set value for POOL_NAME in ${PARENT}/env with${NC} '${FG_GREEN}${pool_name}${NC}'"
                fi
              fi
              echo
              if [[ ${op_mode} = "online" ]]; then
                total_pledge=0
                for wallet_name in "${owner_wallets[@]}"; do
                  getBaseAddress ${wallet_name}
                  getBalance ${base_addr}
                  total_pledge=$(( total_pledge + assets[lovelace] ))
                  getRewards ${wallet_name}
                  [[ ${reward_lovelace} -gt 0 ]] && total_pledge=$(( total_pledge + reward_lovelace ))
                done
                println DEBUG "${FG_BLUE}INFO${NC}: Total balance in ${FG_LBLUE}${#owner_wallets[@]}${NC} owner/pledge wallet(s) are: ${FG_LBLUE}$(formatLovelace ${total_pledge})${NC} Ada"
                if [[ ${total_pledge} -lt ${pledge_lovelace} ]]; then
                  println ERROR "${FG_YELLOW}Not enough funds in owner/pledge wallet(s) to meet set pledge, please manually verify!!!${NC}"
                fi
              fi
              if [[ ${#owner_wallets[@]} -gt 1 ]]; then
                if [[ ${op_mode} = "hybrid" ]]; then
                  println DEBUG "${FG_BLUE}INFO${NC}: please verify that all owner/reward wallets are delegated to the pool after the pool registration has been signed and submitted, if not do so!"
                else
                  println DEBUG "${FG_BLUE}INFO${NC}: please verify that all owner/reward wallets are delegated to the pool, if not do so!"
                fi
              fi
              waitForInput && continue
              ;; ###################################################################
            retire)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> RETIRE"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available to pay for pool de-registration!${NC}" && waitForInput && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitForInput && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "# Select pool to retire"
              if [[ ${op_mode} = "online" ]]; then
                selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: signing keys missing from pool!" && waitForInput && continue ;;
                esac
              else
                selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
              fi
              echo
              epoch=$(getEpoch)
              poolRetireMaxEpoch=$(jq -r '.poolRetireMaxEpoch' <<< "${PROT_PARAMS}")
              println DEBUG "Current epoch: ${FG_LBLUE}${epoch}${NC}"
              epoch_start=$((epoch + 1))
              epoch_end=$((epoch + poolRetireMaxEpoch))
              println DEBUG "earliest epoch to retire pool is ${FG_LBLUE}${epoch_start}${NC} and latest ${FG_LBLUE}${epoch_end}${NC}"
              echo
              getAnswerAnyCust epoch_enter "Enter epoch in which to retire pool (blank for ${epoch_start})"
              [[ -z "${epoch_enter}" ]] && epoch_enter=${epoch_start}
              echo
              if [[ ${epoch_enter} -lt ${epoch_start} || ${epoch_enter} -gt ${epoch_end} ]]; then
                println ERROR "${FG_RED}ERROR${NC}: epoch invalid, valid range: ${epoch_start}-${epoch_end}"
                waitForInput && continue
              fi
              println DEBUG "# Select wallet for pool de-registration transaction fee"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "balance" "${WALLET_PAY_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for pool de-registration transaction fee!" && waitForInput && continue ;;
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
                esac
              else
                selectWallet "balance" "${WALLET_PAY_VK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for pool de-registration transaction fee!" && waitForInput && continue ;;
                esac
              fi
              getBaseAddress ${wallet_name}
              getPayAddress ${wallet_name}
              getBalance ${base_addr}
              base_lovelace=${assets[lovelace]}
              getBalance ${pay_addr}
              pay_lovelace=${assets[lovelace]}
              if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                # Both payment and base address available with funds, let user choose what to use
                println DEBUG "\n# Select wallet address to use"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
                select_opt "[b] Base (default)" "[e] Enterprise" "[Esc] Cancel"
                case $? in
                  0) addr="${base_addr}" ;;
                  1) addr="${pay_addr}" ;;
                  2) continue ;;
                esac
              elif [[ ${pay_lovelace} -gt 0 ]]; then
                addr="${pay_addr}"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "\n$(printf "%s\t${FG_LBLUE}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
              elif [[ ${base_lovelace} -gt 0 ]]; then
                addr="${base_addr}"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "\n$(printf "%s\t\t${FG_LBLUE}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                waitForInput && continue
              fi
              pool_deregcert_file="${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}"
              pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"
              println LOG "creating de-registration cert"
              println ACTION "${CCLI} stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file}"
              ${CCLI} stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file}
              echo
              if ! deRegisterPool; then
                waitForInput && continue
              fi
              [[ -f "${pool_regcert_file}" ]] && rm -f ${pool_regcert_file} # delete registration cert
              echo
              if ! verifyTx ${addr}; then waitForInput && continue; fi
              echo
              println "Pool ${FG_GREEN}${pool_name}${NC} set to be retired in epoch ${FG_LBLUE}${epoch_enter}${NC}"
              println "Pool deposit will be returned to owner reward address after its retired"
              waitForInput && continue
              ;; ###################################################################
            list)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> LIST"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue
              current_epoch=$(getEpoch)
              while IFS= read -r -d '' pool; do
                echo
                pool_name="$(basename ${pool})"
                getPoolID "${pool_name}"
                pool_regcert_file="${pool}/${POOL_REGCERT_FILENAME}"
                isPoolRegistered "${pool_name}"
                case $? in
                  0) println "ERROR" "${FG_RED}KOIOS_API ERROR${NC}: ${error_msg}" && waitForInput && continue ;;
                  1) pool_registered="${FG_RED}NO${NC}" ;;
                  2) pool_registered="${FG_GREEN}YES${NC}" ;;
                  3) if [[ ${current_epoch} -lt ${p_retiring_epoch} ]]; then
                       pool_registered="${FG_YELLOW}YES${NC} - Retiring in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
                     else
                       pool_registered="${FG_RED}NO${NC} - Retired in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
                     fi ;;
                esac
                enc_files=$(find "${pool}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c)
                if [[ ${enc_files} -gt 0 ]]; then
                  println "${FG_GREEN}${pool_name}${NC} (${FG_YELLOW}encrypted${NC})"
                else
                  println "${FG_GREEN}${pool_name}${NC}"
                fi
                println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" "ID (hex)" "${pool_id}")"
                [[ -n ${pool_id_bech32} ]] && println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" "ID (bech32)" "${pool_id_bech32}")"
                println "$(printf "%-21s : %s" "Registered" "${pool_registered}")"
                unset pool_kes_start
                if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
                  getNodeMetrics
                else
                  [[ -f "${pool}/${POOL_CURRENT_KES_START}" ]] && pool_kes_start="$(cat "${pool}/${POOL_CURRENT_KES_START}")"
                fi
                if ! kesExpiration ${pool_kes_start}; then 
                  println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_RED}%s${NC}%s${FG_GREEN}%s${NC}" "KES expiration date" "ERROR" ": failure during KES calculation for " "$(basename ${pool})")"
                else
                  if [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
                    if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
                      println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_RED}%s${NC} %s ago" "KES expiration date" "${kes_expiration}" "EXPIRED!" "$(timeLeft ${expiration_time_sec_diff:1})")"
                    else
                      println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_RED}%s${NC} %s until expiration" "KES expiration date" "${kes_expiration}" "ALERT!" "$(timeLeft ${expiration_time_sec_diff})")"
                    fi
                  elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
                    println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_YELLOW}%s${NC} %s until expiration" "KES expiration date" "${kes_expiration}" "WARNING!" "$(timeLeft ${expiration_time_sec_diff})")"
                  else
                    println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" "KES expiration date" "${kes_expiration}")"
                  fi
                fi
              done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
              echo
              waitForInput && continue
              ;; ###################################################################
            show)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> SHOW"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, locally saved info shown!"
              fi
              tput sc
              selectPool "all" "${POOL_ID_FILENAME}"
              case $? in
                1) waitForInput; continue ;;
                2) continue ;;
              esac
              current_epoch=$(getEpoch)
              getPoolID ${pool_name}
              tput rc && tput ed
              if [[ ${CNTOOLS_MODE} = "CONNECTED" && -z ${KOIOS_API} ]]; then
                println DEBUG "Koios API disabled/unreachable, do you want to proceed querying pool parameters from node?"
                println DEBUG "This is a heavy process and requiring several gigabytes of memory on MainNet."
                select_opt "[y] Yes" "[n] No, abort"
                [[ $? -eq 1 ]] && continue
                tput sc && println DEBUG "Quering pool parameters from node, can take a while...\n"
                println ACTION "${CCLI} query pool-params --stake-pool-id ${pool_id_bech32} ${NETWORK_IDENTIFIER}"
                if ! pool_params=$(${CCLI} query pool-params --stake-pool-id ${pool_id_bech32} ${NETWORK_IDENTIFIER} 2>&1); then
                  tput rc && tput ed
                  println ERROR "${FG_RED}ERROR${NC}: pool-params query failed: ${pool_params}"
                  waitForInput && continue
                fi
                tput rc && tput ed
              fi
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                pool_registered="${FG_LGRAY}status unavailable in offline mode${NC}"
              elif [[ -z ${KOIOS_API} ]]; then
                ledger_pParams=$(jq -r '.poolParams // empty' <<< ${pool_params})
                ledger_fPParams=$(jq -r '.futurePoolParams // empty' <<< ${pool_params})
                ledger_retiring=$(jq -r '.retiring // empty' <<< ${pool_params})
                [[ -z ${ledger_retiring} ]] && p_retiring_epoch=0 || p_retiring_epoch=${ledger_retiring}
                [[ -z "${ledger_fPParams}" ]] && ledger_fPParams="${ledger_pParams}"
                [[ -n "${ledger_pParams}" ]] && pool_registered="${FG_GREEN}YES${NC}" || pool_registered="${FG_RED}NO${NC}"
              else
                println DEBUG "\n${FG_YELLOW}> Querying Koios API for pool information (some data can have a delay of up to 10min)${NC}"
                isPoolRegistered ${pool_name} # variables set in isPoolRegistered [pool_info, error_msg, p_<metric>]
                case $? in
                  0) println "ERROR" "\n${FG_RED}KOIOS_API ERROR${NC}: ${error_msg}" && waitForInput && continue ;;
                  1) pool_registered="${FG_RED}NO${NC}" ;;
                  2) pool_registered="${FG_GREEN}YES${NC}" ;;
                  3) if [[ ${current_epoch} -lt ${p_retiring_epoch} ]]; then
                       pool_registered="${FG_YELLOW}YES${NC} - Retiring in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
                     else
                       pool_registered="${FG_RED}NO${NC} - Retired in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
                     fi ;;
                esac
              fi
              echo
              [[ -n ${p_active_epoch_no} && ${p_active_epoch_no} -gt ${current_epoch} ]] && println "${FG_YELLOW}Pool modified recently, displaying latest registration update.${NC}\n"
              println "$(printf "%-21s : ${FG_GREEN}%s${NC}" "Pool Name" "${pool_name}")"
              println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" "ID (hex)" "${pool_id}")"
              [[ -n ${pool_id_bech32} ]] && println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" "ID (bech32)" "${pool_id_bech32}")"
              println "$(printf "%-21s : %s" "Registered" "${pool_registered}")"
              pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta.json"
              pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                if [[ -f "${pool_meta_file}" ]]; then
                  println "Metadata"
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "Name" "$(jq -r .name "${pool_meta_file}")")"
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "Ticker" "$(jq -r .ticker "${pool_meta_file}")")"
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "Homepage" "$(jq -r .homepage "${pool_meta_file}")")"
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "Description" "$(jq -r .description "${pool_meta_file}")")"
                  [[ -f "${pool_config}" ]] && meta_url="$(jq -r .json_url "${pool_config}")" || meta_url="---"
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "URL" "${meta_url}")"
                  println "ACTION" "${CCLI} stake-pool metadata-hash --pool-metadata-file ${pool_meta_file}"
                  meta_hash="$( ${CCLI} stake-pool metadata-hash --pool-metadata-file "${pool_meta_file}" )"
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "Hash" "${meta_hash}")"
                fi
              elif [[ ${pool_registered} = *YES* ]]; then
                if [[ -n ${KOIOS_API} ]]; then
                  meta_json_url=${p_meta_url}
                elif [[ -n ${ledger_fPParams} ]]; then
                  meta_json_url=$(jq -r '.metadata.url //empty' <<< "${ledger_fPParams}")
                elif [[ -f "${pool_config}" ]]; then
                  meta_json_url=$(jq -r .json_url "${pool_config}")
                fi
                if [[ -n ${meta_json_url} ]] && curl -sL -f -m ${CURL_TIMEOUT} -o "${TMP_DIR}/url_poolmeta.json" ${meta_json_url}; then
                  println "Metadata"
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "Name" "$(jq -r .name "$TMP_DIR/url_poolmeta.json")")"
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "Ticker" "$(jq -r .ticker "$TMP_DIR/url_poolmeta.json")")"
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "Homepage" "$(jq -r .homepage "$TMP_DIR/url_poolmeta.json")")"
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "Description" "$(jq -r .description "$TMP_DIR/url_poolmeta.json")")"
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "URL" "${meta_json_url}")"
                  println ACTION "${CCLI} stake-pool metadata-hash --pool-metadata-file ${TMP_DIR}/url_poolmeta.json"
                  meta_hash_url="$( ${CCLI} stake-pool metadata-hash --pool-metadata-file "${TMP_DIR}/url_poolmeta.json" )"
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "Hash URL" "${meta_hash_url}")"
                  if [[ -z ${KOIOS_API} ]]; then
                    meta_hash_pParams=$(jq -r '.metadata.hash //empty' <<< "${ledger_pParams}")
                    meta_hash_fPParams=$(jq -r '.metadata.hash //empty' <<< "${ledger_fPParams}")
                  else
                    meta_hash_fPParams=${p_meta_hash}
                    meta_hash_pParams=${meta_hash_fPParams}
                  fi
                  if [[ "${meta_hash_pParams}" = "${meta_hash_fPParams}" ]]; then
                    println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "Hash Ledger" "${meta_hash_pParams}")"
                  else
                    println "$(printf "  %-13s (${FG_LGRAY}%s${NC}) : %s" "Hash Ledger" "old" "${meta_hash_pParams}")"
                    println "$(printf "  %-13s (${FG_YELLOW}%s${NC}) : %s" "Hash Ledger" "new" "${meta_hash_fPParams}")"
                  fi
                else
                  println "$(printf "%-21s : %s" "Metadata" "download failed for ${meta_json_url}")"
                fi
              fi
              if [[ ${CNTOOLS_MODE} = "OFFLINE" && -f "${pool_config}" ]]; then
                conf_pledge=$(jq -r '.pledgeADA //0' "${pool_config}")
                conf_margin=$(jq -r '.margin //0' "${pool_config}")
                conf_cost=$(jq -r '.costADA //0' "${pool_config}")
                conf_owner=$(jq -r '.pledgeWallet //"unknown"' "${pool_config}")
                conf_reward=$(jq -r '.rewardWallet //"unknown"' "${pool_config}")
                println "$(printf "%-21s : ${FG_LBLUE}%s${NC} Ada" "Pledge" "$(formatLovelace $(AdaToLovelace "${conf_pledge}"))")"
                println "$(printf "%-21s : ${FG_LBLUE}%s${NC} %%" "Margin" "${conf_margin}")"
                println "$(printf "%-21s : ${FG_LBLUE}%s${NC} Ada" "Cost" "$(formatLovelace $(AdaToLovelace "${conf_cost}"))")"
                println "$(printf "%-21s : ${FG_GREEN}%s${NC} (%s)" "Owner Wallet" "${conf_owner}" "primary only, use online mode for multi-owner")"
                println "$(printf "%-21s : ${FG_GREEN}%s${NC}" "Reward Wallet" "${conf_reward}")"
                relay_title="Relay(s)"
                while read -r type address port; do
                  if [[ ${type} != "DNS_A" && ${type} != "IPv4" && ${type} != "IPv6" ]]; then
                    println "$(printf "%-21s : ${FG_YELLOW}%s${NC}" "${relay_title}" "unknown type (only IPv4/v6/DNS supported in CNTools)")"
                  else
                    println "$(printf "%-21s : ${FG_LGRAY}%s:%s${NC}" "${relay_title}" "${address}" "${port}")"
                  fi
                  relay_title=""
                done < <(jq -r '.relays[] | "\(.type) \(.address) \(.port)"' "${pool_config}")
              elif [[ ${pool_registered} = *YES* ]]; then
                # get pledge
                if [[ -z ${KOIOS_API} ]]; then
                  pParams_pledge=$(jq -r '.pledge //0' <<< "${ledger_pParams}")
                  fPParams_pledge=$(jq -r '.pledge //0' <<< "${ledger_fPParams}")
                else
                  fPParams_pledge=${p_pledge}
                  pParams_pledge=${fPParams_pledge}
                fi
                if [[ ${pParams_pledge} -eq ${fPParams_pledge} ]]; then
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} Ada" "Pledge" "$(formatLovelace "${pParams_pledge}")")"
                else
                  println "$(printf "%-15s (${FG_YELLOW}%s${NC}) : ${FG_LBLUE}%s${NC} Ada" "Pledge" "new" "$(formatLovelace "${fPParams_pledge}")" )"
                fi
                [[ -n ${KOIOS_API} ]] && println "$(printf "%-21s : ${FG_LBLUE}%s${NC} Ada" "Live Pledge" "$(formatLovelace "${p_live_pledge}")")"
                
                # get margin
                if [[ -z ${KOIOS_API} ]]; then
                  pParams_margin=$(LC_NUMERIC=C printf "%.4f" "$(jq -r '.margin //0' <<< "${ledger_pParams}")")
                  fPParams_margin=$(LC_NUMERIC=C printf "%.4f" "$(jq -r '.margin //0' <<< "${ledger_fPParams}")")
                else
                  fPParams_margin=$(LC_NUMERIC=C printf "%.4f" "${p_margin}")
                  pParams_margin=${fPParams_margin}
                fi
                if [[ "${pParams_margin}" = "${fPParams_margin}" ]]; then
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} %%" "Margin" "$(fractionToPCT "${pParams_margin}")")"
                else
                  println "$(printf "%-15s (${FG_YELLOW}%s${NC}) : ${FG_LBLUE}%s${NC} %%" "Margin" "new" "$(fractionToPCT "${fPParams_margin}")" )"
                fi
                
                # get fixed cost
                if [[ -z ${KOIOS_API} ]]; then
                  pParams_cost=$(jq -r '.cost //0' <<< "${ledger_pParams}")
                  fPParams_cost=$(jq -r '.cost //0' <<< "${ledger_fPParams}")
                else
                  fPParams_cost=${p_fixed_cost}
                  pParams_cost=${fPParams_cost}
                fi
                if [[ ${pParams_cost} -eq ${fPParams_cost} ]]; then
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} Ada" "Cost" "$(formatLovelace "${pParams_cost}")")"
                else
                  println "$(printf "%-15s (${FG_YELLOW}%s${NC}) : ${FG_LBLUE}%s${NC} Ada" "Cost" "new" "$(formatLovelace "${fPParams_cost}")" )"
                fi
                
                # get relays
                if [[ -z ${KOIOS_API} ]]; then
                  relays=$(jq -c '.relays[] //empty' <<< "${ledger_fPParams}")
                  if [[ ${relays} != $(jq -c '.relays[] //empty' <<< "${ledger_pParams}") ]]; then
                    println "$(printf "%-23s ${FG_YELLOW}%s${NC}" "" "Relay(s) updated, showing latest registered")"
                  fi
                else
                  relays=$(jq -c '.[] //empty' <<< "${p_relays}")
                fi
                relay_title="Relay(s)"
                if [[ -n "${relays}" ]]; then
                  while read -r relay; do
                    relay_addr=""; relay_port=""                  
                    if [[ -z ${KOIOS_API} ]]; then
                      relay_addr="$(jq -r '."single host address".IPv4 //empty' <<< ${relay})"
                      if [[ -n ${relay_addr} ]]; then
                        relay_port="$(jq -r '."single host address".port //empty' <<< ${relay})"
                      else
                        relay_addr="$(jq -r '."single host name".dnsName //empty' <<< ${relay})"
                        if [[ -n ${relay_addr} ]]; then
                          relay_port="$(jq -r '."single host name".port //empty' <<< ${relay})"
                        else
                          relay_addr="$(jq -r '."single host address".IPv6 //empty' <<< ${relay})"
                          if [[ -n ${relay_addr} ]]; then
                            relay_port="$(jq -r '."single host address".port //empty' <<< ${relay})"
                          else
                            relay_addr="unknown type"
                            relay_port=" only IPv4/v6/DNS supported in CNTools"
                          fi
                        fi
                      fi
                    else
                      relay_addr="$(jq -r '.ipv4 //empty' <<< ${relay})"
                      relay_port="$(jq -r '.port //empty' <<< ${relay})"
                      if [[ -z ${relay_addr} ]]; then
                        relay_addr="$(jq -r '.dns //empty' <<< ${relay})"
                        if [[ -z ${relay_addr} ]]; then
                          relay_addr="$(jq -r '.ipv6 //empty' <<< ${relay})"
                          if [[ -z ${relay_addr} ]]; then
                            relay_addr="$(jq -r '.srv //empty' <<< ${relay})"
                            if [[ -z ${relay_addr} ]]; then
                              relay_addr="unknown type"
                              relay_port=" only IPv4/v6/DNS/SRV supported in CNTools"
                            fi
                          fi
                        fi
                      fi
                    fi
                    println "$(printf "%-21s : ${FG_LGRAY}%s:%s${NC}" "${relay_title}" "${relay_addr}" "${relay_port}")"
                    relay_title=""
                  done <<< "${relays}"
                fi
                
                # get owners
                if [[ -z ${KOIOS_API} ]]; then
                  owners=$(jq -rc '.owners[] // empty' <<< "${ledger_fPParams}")
                  if [[ ${owners} != $(jq -rc '.owners[] // empty' <<< "${ledger_pParams}") ]]; then
                    println "$(printf "%-23s ${FG_YELLOW}%s${NC}" "" "Owner(s) updated, showing latest registered")"
                  fi
                else
                  owners=$(jq -rc '.[] //empty' <<< "${p_owners}")
                fi
                owner_title="Owner(s)"
                while read -r owner; do
                  owner_wallet=$(grep -r ${owner} "${WALLET_FOLDER}" | head -1 | cut -d':' -f1)
                  if [[ -n ${owner_wallet} ]]; then
                    owner_wallet="$(basename "$(dirname "${owner_wallet}")")"
                    println "$(printf "%-21s : ${FG_GREEN}%s${NC}" "${owner_title}" "${owner_wallet}")"
                  else
                    println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" "${owner_title}" "${owner}")"
                  fi
                  owner_title=""
                done <<< "${owners}"
                
                # get reward account
                if [[ -z ${KOIOS_API} ]]; then
                  reward_account=$(jq -r '.rewardAccount.credential."key hash" // empty' <<< "${ledger_fPParams}")
                  if [[ ${reward_account} != $(jq -r '.rewardAccount.credential."key hash" // empty' <<< "${ledger_pParams}") ]]; then
                    println "$(printf "%-23s ${FG_YELLOW}%s${NC}" "" "Reward account updated, showing latest registered")"
                  fi
                else
                  reward_account=${p_reward_addr}
                fi
                if [[ -n ${reward_account} ]]; then
                  reward_wallet=$(grep -r ${reward_account} "${WALLET_FOLDER}" | head -1 | cut -d':' -f1)
                  if [[ -n ${reward_wallet} ]]; then
                    reward_wallet="$(basename "$(dirname "${reward_wallet}")")"
                    println "$(printf "%-21s : ${FG_GREEN}%s${NC}" "Reward wallet" "${reward_wallet}")"
                  else
                    println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" "Reward account" "${reward_account}")"
                  fi
                fi
                
                if [[ -z ${KOIOS_API} ]]; then
                  # get stake distribution
                  println "ACTION" "LC_NUMERIC=C printf %.10f \$(${CCLI} query stake-distribution ${NETWORK_IDENTIFIER} | grep ${pool_id_bech32} | tr -s ' ' | cut -d ' ' -f 2))"
                  stake_pct=$(fractionToPCT "$(LC_NUMERIC=C printf "%.10f" "$(${CCLI} query stake-distribution ${NETWORK_IDENTIFIER} | grep "${pool_id_bech32}" | tr -s ' ' | cut -d ' ' -f 2)")")
                  if validateDecimalNbr ${stake_pct}; then
                    println "$(printf "%-21s : ${FG_LBLUE}%s${NC} %%" "Stake distribution" "${stake_pct}")"
                  fi
                else
                  # get active/live stake/block info
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} Ada" "Active Stake" "$(formatLovelace "${p_active_stake}")")"
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC}" "Lifetime Blocks" "${p_block_count}")"
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} Ada" "Live Stake" "$(formatLovelace "${p_live_stake}")")"
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} (incl owners)" "Delegators" "${p_live_delegators}")"
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} %%" "Saturation" "${p_live_saturation}")"
                fi

                unset pool_kes_start
                if [[ -n ${KOIOS_API} ]]; then
                  [[ ${p_op_cert_counter} != null ]] && kes_counter_str="${FG_LBLUE}${p_op_cert_counter}${FG_LGRAY} - use counter ${FG_LBLUE}$((p_op_cert_counter+1))${FG_LGRAY} for rotation in offline mode.${NC}" || kes_counter_str="${FG_LGRAY}No blocks minted so far with active operational certificate. Use counter ${FG_LBLUE}0${FG_LGRAY} for rotation in offline mode.${NC}"
                  println "$(printf "%-21s : %s" "KES counter" "${kes_counter_str}")"
                elif [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
                  pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"
                  println ACTION "${CCLI} query kes-period-info --op-cert-file ${pool_opcert_file} ${NETWORK_IDENTIFIER}"
                  if ! kes_period_info=$(${CCLI} query kes-period-info --op-cert-file "${pool_opcert_file}" ${NETWORK_IDENTIFIER}); then
                    kes_counter_str="${FG_RED}ERROR${NC}: failed to grab counter from node: [${FG_LGRAY}${kes_period_info}${NC}]"
                  else
                    if op_cert_counter=$(awk '/{/,0' <<< "${kes_period_info}" | jq -er '.qKesNodeStateOperationalCertificateNumber' 2>/dev/null); then
                      kes_counter_str="${FG_LBLUE}${op_cert_counter}${FG_LGRAY} - use counter ${FG_LBLUE}$((op_cert_counter+1))${FG_LGRAY} for rotation in offline mode.${NC}"
                    else
                      kes_counter_str="${FG_LGRAY}No blocks minted so far with active operational certificate. Use counter ${FG_LBLUE}0${FG_LGRAY} for rotation in offline mode.${NC}"
                    fi
                  fi
                  println "$(printf "%-21s : %s" "KES counter" "${kes_counter_str}")"
                  getNodeMetrics
                else
                  [[ -f "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}" ]] && pool_kes_start="$(cat "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}")"
                fi
                if ! kesExpiration ${pool_kes_start}; then 
                  println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_RED}%s${NC}%s${FG_GREEN}%s${NC}" "KES expiration date" "ERROR" ": failure during KES calculation for " "$(basename ${pool})")"
                else
                  if [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
                    if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
                      println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_RED}%s${NC} %s ago" "KES expiration date" "${kes_expiration}" "EXPIRED!" "$(timeLeft ${expiration_time_sec_diff:1})")"
                    else
                      println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_RED}%s${NC} %s until expiration" "KES expiration date" "${kes_expiration}" "ALERT!" "$(timeLeft ${expiration_time_sec_diff})")"
                    fi
                  elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
                    println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_YELLOW}%s${NC} %s until expiration" "KES expiration date" "${kes_expiration}" "WARNING!" "$(timeLeft ${expiration_time_sec_diff})")"
                  else
                    println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" "KES expiration date" "${kes_expiration}")"
                  fi
                fi
              fi
              waitForInput && continue
              ;; ###################################################################
            rotate)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> ROTATE KES"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, please grab correct counter value from online node using pool info!\n"
              fi
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue
              println DEBUG "# Select pool to rotate KES keys on"
              selectPool "all" "${POOL_COLDKEY_VK_FILENAME}"
              case $? in
                1) waitForInput; continue ;;
                2) continue ;;
              esac
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                getAnswerAnyCust new_counter "Enter new counter number"
                if ! isNumber ${new_counter}; then
                  println ERROR "\n${FG_RED}ERROR${NC}: not a number"
                  waitForInput && continue
                fi
                if ! rotatePoolKeys ${new_counter}; then
                  waitForInput && continue
                fi
              else
                if ! rotatePoolKeys; then
                  waitForInput && continue
                fi
              fi
              echo
              println "Pool KES keys successfully updated"
              println "New KES start period : ${FG_LBLUE}${current_kes_period}${NC}"
              println "KES keys will expire : ${FG_LBLUE}$(( current_kes_period + MAX_KES_EVOLUTIONS ))${NC} - ${FG_LGRAY}${kes_expiration}${NC}"
              echo
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "Copy updated files to pool node replacing existing files:"
                println DEBUG "${FG_LGRAY}${pool_hotkey_sk_file}${NC}"
                println DEBUG "${FG_LGRAY}${pool_opcert_file}${NC}"
                echo
              fi
              println DEBUG "Restart your pool node for changes to take effect"
              waitForInput && continue
              ;; ###################################################################
            decrypt)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> DECRYPT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue
              println DEBUG "# Select pool to decrypt"
              selectPool "encrypted"
              case $? in
                1) waitForInput; continue ;;
                2) continue ;;
              esac
              filesUnlocked=0
              keysDecrypted=0
              echo
              println DEBUG "# Removing write protection from all pool files"
              while IFS= read -r -d '' file; do
                unlockFile "${file}"
                filesUnlocked=$((++filesUnlocked))
                println DEBUG "${file}"
              done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)
              if [[ $(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -gt 0 ]]; then
                echo
                println "# Decrypting GPG encrypted pool files"
                if ! getPasswordCust; then # $password variable populated by getPasswordCust function
                  println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                  waitForInput && continue
                fi
                while IFS= read -r -d '' file; do
                  decryptFile "${file}" "${password}" && \
                  chmod 600 "${file::-4}" && \
                  keysDecrypted=$((++keysDecrypted))
                done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
                unset password
              fi
              echo
              println "Pool decrypted  : ${FG_GREEN}${pool_name}${NC}"
              println "Files unlocked  : ${FG_LBLUE}${filesUnlocked}${NC}"
              println "Files decrypted : ${FG_LBLUE}${keysDecrypted}${NC}"
              if [[ ${filesUnlocked} -ne 0 || ${keysDecrypted} -ne 0 ]]; then
                echo
                println DEBUG "${FG_YELLOW}Pool files are now unprotected${NC}"
                println DEBUG "Use 'POOL >> ENCRYPT / LOCK' to re-lock"
              fi
              waitForInput && continue
              ;; ###################################################################
            encrypt)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> ENCRYPT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue
              println DEBUG "# Select pool to encrypt"
              selectPool "encrypted"
              case $? in
                1) waitForInput; continue ;;
                2) continue ;;
              esac
              filesLocked=0
              keysEncrypted=0
              if [[ $(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -le 0 ]]; then
                echo
                println DEBUG "# Encrypting sensitive pool keys with GPG"
                if ! getPasswordCust confirm; then # $password variable populated by getPasswordCust function
                  println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                  waitForInput && continue
                fi
                keyFiles=(
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
              else
                echo
                println DEBUG "${FG_YELLOW}NOTE${NC}: found GPG encrypted files in folder, please decrypt/unlock pool files before encrypting"
                waitForInput && continue
              fi
              echo
              println DEBUG "# Write protecting all pool files with 400 permission and if enabled 'chattr +i'"
              while IFS= read -r -d '' file; do
                lockFile "$file"
                filesLocked=$((++filesLocked))
                println DEBUG "$file"
              done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)
              echo
              println "Pool encrypted  : ${FG_GREEN}${pool_name}${NC}"
              println "Files locked    : ${FG_LBLUE}${filesLocked}${NC}"
              println "Files encrypted : ${FG_LBLUE}${keysEncrypted}${NC}"
              if [[ ${filesLocked} -ne 0 || ${keysEncrypted} -ne 0 ]]; then
                echo
                println DEBUG "${FG_BLUE}INFO${NC}: pool files are now protected"
                println DEBUG "Use 'POOL >> DECRYPT / UNLOCK' to unlock"
              fi
              waitForInput && continue
              ;; ###################################################################
            vote)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> VOTE (CIP-0094)"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              # check for required command line tools (xxd hexdump)
              if ! cmdAvailable "xxd"; then 
                myExit 1 "xxd is a hexdump tool to generate the CBOR encoded poll answer"
              fi
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available to pay for poll ballot casts!${NC}" && waitForInput && continue
              if [[ -z ${KOIOS_API} ]]; then
                echo && println ERROR "${FG_YELLOW}Koios API required!${NC}" && waitForInput && continue
              fi
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitForInput && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              epoch=$(getEpoch)
              echo 
              echo "Current ${NETWORK_NAME} epoch: ${epoch}"
              NETWORK_NAME_LOWER=$(echo "$NETWORK_NAME" | awk '{print tolower($0)}')
              println LOG "Query ${NETWORK_NAME} polls ..."
              println ACTION "curl -sSL -f -H \"Content-Type: application/json\" ${CIP0094_POLL_URL}"
              ! polls=$(curl -sSL -f -H "Content-Type: application/json"  "${CIP0094_POLL_URL}" | jq -r .networks.${NETWORK_NAME_LOWER} 2>&1) && waitForInput && continue
              poll_index=$(echo $polls | jq '. | length')
              if [[ "$poll_index" -gt 0 ]]; then
                poll_index_act=0
                poll_index_cnt=0
                declare poll_index_txIds=()
                declare poll_index_titles=()
                echo "Polls currently open for Pool answers:"
                while read poll; do
                  poll_index_cnt=$((poll_index_cnt+1))
                  if [[ "$epoch" -ge "$(jq '.epoch_cast' <<< $poll)" ]] && [[ "$epoch" -lt "$(jq '.epoch_delegation' <<< $poll)" ]]; then
                    # list polls who actually are open for SPO ballot casts (filter upcoming and passed ones)
                    poll_index_act=$((poll_index_act+1))
                    poll_index_txIds+=("$(jq -r '[.tx_id] | @tsv' <<< $poll)")
                    poll_index_titles+=("$(jq -r '[.title] | @tsv' <<< $poll)")
                    echo -e "$poll_index_act) $(jq -r '[.tx_id, .title] | @tsv' <<< $poll)"
                  fi
                done < <(echo $polls | jq -c .[])
                if [[ "$poll_index_act" -gt 0 ]]; then 
                  while :; do
                    read -p "Please select a poll: " poll_index_selected
                    [[ $poll_index_selected =~ ^[[:digit:]]+$ ]] || continue
                      if [[ "$poll_index_selected" -lt "1" ]] || [[ "$poll_index_selected" -gt "$poll_index_act" ]]; then
                      continue
                    fi
                    break
                  done
                  poll_txId=${poll_index_txIds[$((poll_index_selected-1))]}
                  poll_title=${poll_index_titles[$(($poll_index_selected-1))]}
                  echo
                  println DEBUG "# Select the voting pool"
                  if [[ ${op_mode} = "online" ]]; then
                    selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}"
                    case $? in
                      1) waitForInput; continue ;;
                      2) continue ;;
                    esac
                    getPoolType ${pool_name}
                    case $? in
                      2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                      3) println ERROR "${FG_RED}ERROR${NC}: signing keys missing from pool!" && waitForInput && continue ;;
                    esac
                  else
                    selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}"
                    case $? in
                      1) waitForInput; continue ;;
                      2) continue ;;
                    esac
                    getPoolType ${pool_name}
                  fi
                  echo
                  println DEBUG "# Select wallet for the ballot cast transaction fee"
                  if [[ ${op_mode} = "online" ]]; then
                    selectWallet "balance" "${WALLET_PAY_VK_FILENAME}"
                    case $? in
                      1) waitForInput; continue ;;
                      2) continue ;;
                    esac
                    getWalletType ${wallet_name}
                    case $? in
                      0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for transaction fee!" && waitForInput && continue ;;
                      2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                      3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
                    esac
                  else
                    selectWallet "balance" "${WALLET_PAY_VK_FILENAME}"
                    case $? in
                      1) waitForInput; continue ;;
                      2) continue ;;
                    esac
                    getWalletType ${wallet_name}
                    case $? in
                      0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for transaction fee!" && waitForInput && continue ;;
                    esac
                  fi
                  getBaseAddress ${wallet_name}
                  getPayAddress ${wallet_name}
                  getBalance ${base_addr}
                  base_lovelace=${assets[lovelace]}
                  getBalance ${pay_addr}
                  pay_lovelace=${assets[lovelace]}
                  if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                    # Both payment and base address available with funds, let user choose what to use
                    println DEBUG "\n# Select wallet address to use"
                    if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                      println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
                      println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
                    fi
                    select_opt "[b] Base (default)" "[e] Enterprise" "[Esc] Cancel"
                    case $? in
                      0) addr="${base_addr}" ;;
                      1) addr="${pay_addr}" ;;
                      2) continue ;;
                    esac
                  elif [[ ${pay_lovelace} -gt 0 ]]; then
                    addr="${pay_addr}"
                    if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                      println DEBUG "\n$(printf "%s\t${FG_LBLUE}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
                    fi
                  elif [[ ${base_lovelace} -gt 0 ]]; then
                    addr="${base_addr}"
                    if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                      println DEBUG "\n$(printf "%s\t\t${FG_LBLUE}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
                    fi
                  else
                    println ERROR "\n${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                    waitForInput && continue
                  fi
                  echo
                  echo "Query ${NETWORK_NAME} ${poll_txId} metadata from Koios API..."
                  println ACTION "curl -sSL -f -X POST -H \"Content-Type: application/json\" -d '{\"_tx_hashes\":[\"${poll_txId}\"]}' ${KOIOS_API}/tx_metadata"
                  ! tx=$(curl -sSL -f -X POST -H "Content-Type: application/json" -d '{"_tx_hashes":["'${poll_txId}'"]}' "${KOIOS_API}/tx_metadata" 2>&1) && error_msg=${tx} && waitForInput && continue
                  tx_meta=$(echo ${tx} | jq -r ".[0].metadata.\"94\" // empty" 2> /dev/null  )
                  if [[ ! -z ${tx_meta} ]]; then
                    echo "OK: Metadata has a CIP-0094 label"
                    #Variables for the Question and the Options
                    #this code part was originaly written by SPO Scripts (https://github.com/gitmachtl/scripts/blob/master/cardano/testnet/13a_spoPoll.sh)
                    questionString=""   #string that holds the question
                    optionString=()     #array of options
                    #Question found now convert it to cbor
                    cborStr="" #setup a clear new cbor string variable
                    cborStr+=$(to_cbor "map" 1) #map 1
                    cborStr+=$(to_cbor "unsigned" 94) #unsigned 94
                    cborStr+=$(to_cbor "map" 2) #map 2
                    cborStr+=$(to_cbor "unsigned" 0) #unsigned 0
                    #Add QuestionStrings
                    questionStrLength=$(jq -r ".\"0\" | length" <<< ${tx_meta} 2> /dev/null)
                    if [[ ${questionStrLength} -eq 0 ]]; then
                        echo -e "\n${FG_RED}ERROR - No question string included\n${NC}" && waitForInput && continue
                    fi
                    cborStr+=$(to_cbor "array" ${questionStrLength}) #array with the number of entries
                    for (( tmpCnt=0; tmpCnt<${questionStrLength}; tmpCnt++ ))
                    do
                        strEntry=$(jq -r ".\"0\"[${tmpCnt}]" <<< ${tx_meta} 2> /dev/null)
                        cborStr+=$(to_cbor "string" "${strEntry}") #string
                        questionString+="${strEntry}"
                    done
                    cborStr+=$(to_cbor "unsigned" 1) #unsigned 1
                    #Add OptionsStrings
                    optionsStrLength=$(jq -r ".\"1\" | length" <<< ${tx_meta} 2> /dev/null)
                    if [[ ${optionsStrLength} -eq 0 ]]; then
                        echo -e "\n${FG_RED}ERROR - No option strings included\n${NC}" && waitForInput && continue
                    fi
                    cborStr+=$(to_cbor "array" ${optionsStrLength}) #array with the number of options
                    
                    for (( tmpCnt=0; tmpCnt<${optionsStrLength}; tmpCnt++ ))
                    do
                        optionEntryStrLength=$(jq -r ".\"1\"[${tmpCnt}] | length" <<< ${tx_meta} 2> /dev/null)
                        cborStr+=$(to_cbor "array" ${optionEntryStrLength}) #array with the number of entries
                        for (( tmpCnt2=0; tmpCnt2<${optionEntryStrLength}; tmpCnt2++ ))
                        do
                            strEntry=$(jq -r ".\"1\"[${tmpCnt}][${tmpCnt2}]" <<< ${tx_meta} 2> /dev/null)
                            cborStr+=$(to_cbor "string" "${strEntry}") #string
                            optionString[${tmpCnt}]+="${strEntry}"
                        done
                    done
                    #Show the question and the available answer options
                    echo
                    echo -e "${FG_GREEN}Question${NC}: ${questionString}"
                    echo
                    echo -e "There are ${optionsStrLength} answer option(s) available:"
                    for (( tmpCnt=0; tmpCnt<${optionsStrLength}; tmpCnt++ ))
                    do
                     echo -e "[${FG_YELLOW}${tmpCnt}${NC}] ${optionString[${tmpCnt}]}"
                    done
                    echo
                    #Read in the answer, loop until a valid answer index is given
                    answer="-1"
                    while [ -z "${answer##*[!0-9]*}" ] || [[ ${answer} -lt 0 ]] || [[ ${answer} -ge ${optionsStrLength} ]];
                    do
                        read -p $'Please indicate an answer (by index): ' answer
                        if [[ ${answer} == "" ]]; then 
                          echo && println "${FG_YELLOW}No answer${NC}" && waitForInput && continue
                        fi
                    done
                    echo
                    echo -e "Your answer is '${optionString[${answer}]}'."
                    echo
                    #Generating the answer cbor
                    questionHash=$(echo -n "${cborStr}" | xxd -r -ps | b2sum -l 256 -b | cut -d' ' -f 1)
                    #Make a new cborStr with the answer
                    cborStr="" #setup a clear new cbor string variable
                    cborStr+=$(to_cbor "map" 1) #map 1
                    cborStr+=$(to_cbor "unsigned" 94) #unsigned 94
                    cborStr+=$(to_cbor "map" 2) #map 2
                    cborStr+=$(to_cbor "unsigned" 2) #unsigned 2
                    cborStr+=$(to_cbor "bytes" "${questionHash}") #bytearray of the blake2b-256 hash of the question cbor
                    cborStr+=$(to_cbor "unsigned" 3) #unsigned 3
                    cborStr+=$(to_cbor "unsigned" ${answer}) #unsigned - answer index
                    #CBOR Answer is ready, write it out to disc
                    cborFile="${TMP_DIR}/CIP-0094_${poll_txId}_answer.cbor"
                    #echo -ne "Writing '${cborFile}' to disc ... "
                    xxd -r -ps <<< ${cborStr} 2> /dev/null > ${cborFile}
                    if [ $? -ne 0 ]; then echo -e "\n\n${FG_RED}ERROR, could not write to file!\n\n${NC}"; exit 1; fi
                    # Optional metadata/message
                    println "# Add a message to the answer? (Poll Dashboards will show this message)"
                    select_opt "[n] No" "[y] Yes"
                    case $? in
                      0)  unset metafile ;;
                      1)  metafile="${TMP_DIR}/metadata_$(date '+%Y%m%d%H%M%S').json"
                          DEFAULTEDITOR="$(command -v nano &>/dev/null && echo 'nano' || echo 'vi')"
                          println OFF "\nA maximum of 64 characters(bytes) is allowed per line."
                          println OFF "${FG_YELLOW}Please don't change default file path when saving.${NC}"
                          exec >&6 2>&7 # normal stdout/stderr
                          waitForInput "press any key to open '${FG_LGRAY}${DEFAULTEDITOR}${NC}' text editor"
                          ${DEFAULTEDITOR} "${metafile}"
                          exec >&8 2>&9 # custom stdout/stderr
                          if [[ ! -f "${metafile}" ]]; then
                            println ERROR "${FG_RED}ERROR${NC}: file not found"
                            println ERROR "File: ${FG_LGRAY}${metafile}${NC}"
                            waitForInput && continue
                          fi
                          tput cuu 4 && tput ed
                          if [[ ! -s ${metafile} ]]; then
                            println "Message empty, skip and continue with answer without message? No to abort!"
                            select_opt "[y] Yes" "[n] No"
                            case $? in
                              0) unset metafile ;;
                              1) continue ;;
                            esac
                          else
                            tx_msg='{"674":{"msg":[]}}'
                            error=""
                            while IFS="" read -r line || [[ -n "${line}" ]]; do
                              line_bytes=$(echo -n "${line}" | wc -c)
                              if [[ ${line_bytes} -gt 64 ]]; then
                                error="${FG_RED}ERROR${NC}: line contains more that 64 bytes(characters) [${line_bytes}]\nLine: ${FG_LGRAY}${line}${NC}" && break
                              fi
                              if ! tx_msg=$(jq -er ".\"674\".msg += [\"${line}\"]" <<< "${tx_msg}" 2>&1); then
                                error="${FG_RED}ERROR${NC}: ${tx_msg}" && break
                              fi
                            done < "${metafile}"
                            [[ -n ${error} ]] && println ERROR "${error}" && waitForInput && continue
                            jq -c . <<< "${tx_msg}" > "${metafile}"
                            jq -r . "${metafile}" >&3 && echo
                            println LOG "Transaction message: ${tx_msg}"
                          fi
                          ;;
                    esac
                    if ! submitPoll; then
                      waitForInput && continue
                    fi
                  else
                    echo && println "${FG_YELLOW}Cannot find valid metadata for this transaction${NC}" 
                    waitForInput && continue
                  fi
                else
                  echo && println "${FG_YELLOW}There are currently no active polls in ${NETWORK_NAME}${NC}" 
                  waitForInput && continue
                fi
              else
                echo && println "${FG_YELLOW}There are currently no polls in ${NETWORK_NAME}${NC}" 
                waitForInput && continue
              fi
              ;; ###################################################################
          esac # pool sub OPERATION
        done # Pool loop
        ;; ###################################################################
      transaction)
        while true; do # Transaction loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> TRANSACTION"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Transaction Management\n"\
						" ) Sign    - witness/sign offline tx with signing keys"\
						" ) Submit  - submit signed offline tx to blockchain"\
						"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Transaction Operation\n"
          select_opt "[s] Sign" "[t] Submit" "[h] Home"
          case $? in
            0) SUBCOMMAND="sign" ;;
            1) SUBCOMMAND="submit" ;;
            2) break ;;
          esac
          case $SUBCOMMAND in
            sign)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> TRANSACTION >> SIGN"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              fileDialog "Enter path to offline tx file to sign" "${TMP_DIR}/" && echo
              offline_tx=${file}
              [[ -z "${offline_tx}" ]] && continue
              if [[ ! -f "${offline_tx}" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: file not found: ${offline_tx}"
                waitForInput && continue
              elif ! offlineJSON=$(jq -erc . "${offline_tx}"); then
                println ERROR "${FG_RED}ERROR${NC}: invalid JSON file: ${offline_tx}"
                waitForInput && continue
              fi
              if ! otx_type="$(jq -er '.type' <<< ${offlineJSON})"; then println ERROR "${FG_RED}ERROR${NC}: field 'type' not found in: ${offline_tx}" && waitForInput && continue; fi
              if ! otx_date_created="$(jq -er '."date-created"' <<< ${offlineJSON})"; then println ERROR "${FG_RED}ERROR${NC}: field 'date-created' not found in: ${offline_tx}" && waitForInput && continue; fi
              if ! otx_date_expire="$(jq -er '."date-expire"' <<< ${offlineJSON})"; then println ERROR "${FG_RED}ERROR${NC}: field 'date-expire' not found in: ${offline_tx}" && waitForInput && continue; fi
              if ! otx_txFee=$(jq -er '.txFee' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'txFee' not found in: ${offline_tx}" && waitForInput && continue; fi
              if ! otx_txBody=$(jq -er '.txBody' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'txBody' not found in: ${offline_tx}" && waitForInput && continue; fi
              echo -e "${otx_txBody}" > "${TMP_DIR}"/tx.raw
              [[ $(jq -r '."signed-txBody" | length' <<< ${offlineJSON}) -gt 0 ]] && println ERROR "${FG_RED}ERROR${NC}: transaction already signed, please submit transaction to complete!" && waitForInput && continue
              println DEBUG "Transaction type : ${FG_GREEN}${otx_type}${NC}"
              if wallet_name=$(jq -er '."wallet-name"' <<< ${offlineJSON}); then 
                println DEBUG "Transaction fee  : ${FG_LBLUE}$(formatLovelace ${otx_txFee})${NC} Ada, payed by ${FG_GREEN}${wallet_name}${NC}"
                [[ $(cat "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}" 2>/dev/null) = "${addr}" ]] && wallet_source="enterprise" || wallet_source="base"
              else
                println DEBUG "Transaction fee  : ${FG_LBLUE}$(formatLovelace ${otx_txFee})${NC} Ada"
              fi
              println DEBUG "Created          : ${FG_LGRAY}$(date '+%F %T %Z' --date="${otx_date_created}")${NC}"
              if [[ $(date '+%s' --date="${otx_date_expire}") -lt $(date '+%s') ]]; then
                println DEBUG "Expire           : ${FG_RED}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}"
                println ERROR "\n${FG_RED}ERROR${NC}: offline transaction expired!  please create a new one with long enough Time To Live (TTL)"
                waitForInput && continue
              else
                println DEBUG "Expire           : ${FG_LGRAY}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}"
              fi
              tx_witness_files=()
              tx_sign_files=()
              case "${otx_type}" in
                Wallet*|Payment|"Pool De-Registration"|Metadata|Asset*|"Poll Cast")
                  echo
                  [[ ${otx_type} = "Wallet De-Registration" ]] && println DEBUG "Amount returned  : ${FG_LBLUE}$(formatLovelace "$(jq -r '."amount-returned"' <<< ${offlineJSON})")${NC} Ada"
                  if [[ ${otx_type} = "Payment" ]]; then
                    println DEBUG "Source addr      : ${FG_LGRAY}$(jq -r '."source-address"' <<< ${offlineJSON})${NC}"
                    println DEBUG "Destination addr : ${FG_LGRAY}$(jq -r '."destination-address"' <<< ${offlineJSON})${NC}"
                    println DEBUG "Amount           : ${FG_LBLUE}$(formatLovelace "$(jq -r '.assets[] | select(.asset=="lovelace") | .amount' <<< ${offlineJSON})")${NC} Ada"
                    for otx_assets in $(jq -r '.assets[] | @base64' <<< "${offlineJSON}"); do
                      _jq() { base64 -d <<< ${otx_assets} | jq -r "${1}"; }
                      otx_asset=$(_jq '.asset')
                      [[ ${otx_asset} = "lovelace" ]] && continue
                      println DEBUG "                   ${FG_LBLUE}$(formatAsset "$(_jq '.amount')")${NC} ${FG_LGRAY}${otx_asset}${NC}"
                    done
                  fi
                  jq -er '.rewards' <<< ${offlineJSON} &>/dev/null && println DEBUG "Rewards          : ${FG_LBLUE}$(formatLovelace "$(jq -r '.rewards' <<< ${offlineJSON})")${NC} Ada"
                  jq -er '."pool-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Pool ID          : ${FG_LGRAY}$(jq -r '."pool-id"' <<< ${offlineJSON})${NC}"
                  jq -er '."pool-name"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Pool name        : ${FG_LGRAY}$(jq -r '."pool-name"' <<< ${offlineJSON})${NC}"
                  jq -er '."pool-ticker"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Ticker           : ${FG_LGRAY}$(jq -r '."pool-ticker"' <<< ${offlineJSON})${NC}"
                  jq -er '."retire-epoch"' <<< ${offlineJSON} &>/dev/null && println DEBUG "To be retired    : epoch ${FG_LGRAY}$(jq -r '."retire-epoch"' <<< ${offlineJSON})${NC}"
                  jq -er '.metadata' <<< ${offlineJSON} &>/dev/null && println DEBUG "Metadata         :\n$(jq -r '.metadata' <<< ${offlineJSON})\n"
                  jq -er '."policy-name"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Policy Name      : ${FG_LGRAY}$(jq -r '."policy-name"' <<< ${offlineJSON})${NC}"
                  jq -er '."policy-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Policy ID        : ${FG_LGRAY}$(jq -r '."policy-id"' <<< ${offlineJSON})${NC}"
                  jq -er '."asset-name"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Asset Name       : ${FG_LGRAY}$(jq -r '."asset-name"' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Asset Minting" ]] && println DEBUG "Assets To Mint   : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-amount"' <<< ${offlineJSON})")${NC}"
                  [[ ${otx_type} = "Asset Minting" ]] && println DEBUG "Assets Minted    : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-minted"' <<< ${offlineJSON})")${NC}"
                  [[ ${otx_type} = "Asset Burning" ]] && println DEBUG "Assets To Burn   : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-amount"' <<< ${offlineJSON})")${NC}"
                  [[ ${otx_type} = "Asset Burning" ]] && println DEBUG "Assets Left      : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-minted"' <<< ${offlineJSON})")${NC}"
                  [[ ${otx_type} = "Poll Cast" ]] && println DEBUG "Poll ID          : ${FG_LGRAY}$(jq -r '."poll-txId"' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Poll Cast" ]] && println DEBUG "Title            : ${FG_LGRAY}$(jq -r '."poll-title"' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Poll Cast" ]] && println DEBUG "Question         : ${FG_LGRAY}$(jq -r '."poll-question"' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Poll Cast" ]] && println DEBUG "Answer           : ${FG_LGRAY}$(jq -r '."poll-answer"' <<< ${offlineJSON})${NC}"
                  for otx_signing_file in $(jq -r '."signing-file"[] | @base64' <<< "${offlineJSON}"); do
                    _jq() { base64 -d <<< ${otx_signing_file} | jq -r "${1}"; }
                    otx_signing_name=$(_jq '.name')
                    otx_vkey_cborHex="$(_jq '.vkey.cborHex' 2>/dev/null)"
                    
                    skey_path=""
                    # look for signing key in wallet folder
                    while IFS= read -r -d '' w_file; do
                      if [[ ${w_file} = */"${WALLET_PAY_SK_FILENAME}" || ${w_file} = */"${WALLET_STAKE_SK_FILENAME}" ]]; then
                        ! ${CCLI} key verification-key --signing-key-file "${w_file}" --verification-key-file "${TMP_DIR}"/tmp.vkey && continue
                        if [[ $(jq -er '.type' "${w_file}" 2>/dev/null) = *"Extended"* ]]; then
                          ! ${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/tmp.vkey" --verification-key-file "${TMP_DIR}/tmp2.vkey" && continue
                          mv -f "${TMP_DIR}/tmp2.vkey" "${TMP_DIR}/tmp.vkey"
                        fi
                        grep -q "${otx_vkey_cborHex}" "${TMP_DIR}"/tmp.vkey && skey_path="${w_file}" && break
                      elif [[ ${w_file} = */"${WALLET_HW_PAY_SK_FILENAME}" || ${w_file} = */"${WALLET_HW_STAKE_SK_FILENAME}" ]]; then
                        grep -q "${otx_vkey_cborHex:4}" "${w_file}" && skey_path="${w_file}" && break # strip 5820 prefix
                      fi
                    done < <(find "${WALLET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -print0 2>/dev/null)
                    # look for cold signing key in pool folder
                    if [[ -z ${skey_path} ]]; then
                      while IFS= read -r -d '' p_file; do
                        ! ${CCLI} key verification-key --signing-key-file "${p_file}" --verification-key-file "${TMP_DIR}"/tmp.vkey && continue
                        grep -q "${otx_vkey_cborHex}" "${TMP_DIR}"/tmp.vkey && skey_path="${p_file}" && break
                      done < <(find "${POOL_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${POOL_COLDKEY_SK_FILENAME}" -print0 2>/dev/null)
                    fi
                    # look for signing key in asset folder
                    if [[ -z ${skey_path} ]]; then
                      while IFS= read -r -d '' a_file; do
                        ! ${CCLI} key verification-key --signing-key-file "${a_file}" --verification-key-file "${TMP_DIR}"/tmp.vkey && continue
                        grep -q "${otx_vkey_cborHex}" "${TMP_DIR}"/tmp.vkey && skey_path="${a_file}" && break
                      done < <(find "${ASSET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${ASSET_POLICY_SK_FILENAME}" -print0 2>/dev/null)
                    fi

                    if [[ -n ${skey_path} ]]; then
                      println DEBUG "\nFound a match for ${otx_signing_name}, use this file ? : ${FG_LGRAY}${skey_path}${NC}"
                      select_opt "[y] Yes" "[n] No, continue with manual selection"
                      case $? in
                        0)  println DEBUG "${FG_GREEN}Successfully added!${NC}"
                            tx_sign_files+=( "${skey_path}" )
                            continue ;;
                        1)  : ;; # do nothing
                      esac
                    fi

                    if [[ ${otx_signing_name} = "Pool "* ]]; then dialog_start_path="${POOL_FOLDER}"
                    elif [[ ${otx_signing_name} = "Asset "* ]]; then dialog_start_path="${POOL_FOLDER}"
                    else dialog_start_path="${WALLET_FOLDER}"; fi
                    fileDialog "\nEnter path to ${otx_signing_name}" "${dialog_start_path}/"
                    [[ ! -f "${file}" ]] && println ERROR "${FG_RED}ERROR${NC}: file not found: ${file}" && waitForInput && continue 2
                    if [[ ${file} = "${ASSET_POLICY_SCRIPT_FILENAME}" ]]; then
                      if ! grep -q "$(_jq '.script.keyHash')" "${file}"; then
                        println ERROR "${FG_RED}ERROR${NC}: script file provided doesn't match with script hash in offline transaction for: ${otx_signing_name}"
                        println ERROR "Provided asset script keyHash: $(jq -r '.keyHash' "${file}")"
                        println ERROR "Transaction asset script keyHash: $(_jq '.script.keyHash')"
                        waitForInput && continue 2
                      fi
                    elif [[ $(jq -er '.description' "${file}" 2>/dev/null) = *"Hardware"* ]]; then
                      if ! grep -q "${otx_vkey_cborHex:4}" "${file}"; then # strip 5820 prefix
                        println ERROR "${FG_RED}ERROR${NC}: signing key provided doesn't match with verification key in offline transaction for: ${otx_signing_name}"
                        println ERROR "Provided hardware signing key's verification cborXPubKeyHex: $(jq -r .cborXPubKeyHex "${file}")"
                        println ERROR "Transaction verification cborHex: ${otx_vkey_cborHex:4}"
                        waitForInput && continue 2
                      fi
                    else
                      println ACTION "${CCLI} key verification-key --signing-key-file ${file} --verification-key-file ${TMP_DIR}/tmp.vkey"
                      if ! ${CCLI} key verification-key --signing-key-file "${file}" --verification-key-file "${TMP_DIR}"/tmp.vkey; then waitForInput && continue 2; fi
                      if [[ $(jq -r '.type' "${file}") = *"Extended"* ]]; then
                        println ACTION "${CCLI} key non-extended-key --extended-verification-key-file ${TMP_DIR}/tmp.vkey --verification-key-file ${TMP_DIR}/tmp2.vkey"
                        if ! ${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/tmp.vkey" --verification-key-file "${TMP_DIR}/tmp2.vkey"; then waitForInput && continue 2; fi
                        mv -f "${TMP_DIR}/tmp2.vkey" "${TMP_DIR}/tmp.vkey"
                      fi
                      if [[ ${otx_vkey_cborHex} != $(jq -r .cborHex "${TMP_DIR}"/tmp.vkey) ]]; then
                        println ERROR "${FG_RED}ERROR${NC}: signing key provided doesn't match with verification key in offline transaction for: ${otx_signing_name}"
                        println ERROR "Provided signing key's verification cborHex: $(jq -r .cborHex "${TMP_DIR}"/tmp.vkey)"
                        println ERROR "Transaction verification cborHex: ${otx_vkey_cborHex}"
                        waitForInput && continue 2
                      fi
                    fi
                    
                    println DEBUG "${FG_GREEN}Successfully added!${NC}"
                    tx_sign_files+=( "${file}" )
                  done
                  if [[ ${#tx_sign_files[@]} -gt 0 ]]; then
                    if ! witnessTx "${TMP_DIR}/tx.raw" "${tx_sign_files[@]}"; then waitForInput && continue; fi
                    if ! assembleTx "${TMP_DIR}/tx.raw"; then waitForInput && continue; fi
                    echo
                    if jq ". += { \"signed-txBody\": $(jq -c . "${tx_signed}") }" <<< "${offlineJSON}" > "${offline_tx}"; then
                      println "Offline transaction successfully signed"
                      println "please move ${offline_tx} back to online node and submit before ${FG_LGRAY}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}!"
                    else
                      println ERROR "${FG_RED}ERROR${NC}: failed to write signed tx body to offline transaction file!"
                    fi
                  else
                    println ERROR "\n${FG_YELLOW}WARN${NC}: no signing keys added!"
                  fi
                  ;;
                "Pool Registration"|"Pool Update")
                  echo
                  println DEBUG "Pool name        : ${FG_LGRAY}$(jq -r '."pool-metadata".name' <<< ${offlineJSON})${NC}"
                  println DEBUG "Ticker           : ${FG_LGRAY}$(jq -r '."pool-metadata".ticker' <<< ${offlineJSON})${NC}"
                  println DEBUG "Pledge           : ${FG_LBLUE}$(formatLovelace "$(AdaToLovelace "$(jq -r '."pool-pledge"' <<< ${offlineJSON})")")${NC} Ada"
                  println DEBUG "Margin           : ${FG_LBLUE}$(jq -r '."pool-margin"' <<< ${offlineJSON})${NC} %"
                  println DEBUG "Cost             : ${FG_LBLUE}$(formatLovelace "$(AdaToLovelace "$(jq -r '."pool-cost"' <<< ${offlineJSON})")")${NC} Ada"
                  for otx_signing_file in $(jq -r '."signing-file"[] | @base64' <<< "${offlineJSON}"); do
                    _jq() { base64 -d <<< ${otx_signing_file} | jq -r "${1}"; }
                    otx_signing_name=$(_jq '.name')
                    otx_vkey_cborHex="$(_jq '.vkey.cborHex')"

                    for otx_witness in $(jq -r '.witness[] | @base64' <<< "${offlineJSON}"); do
                      __jq() { base64 -d <<< ${otx_witness} | jq -r "${1}"; }
                      [[ $(_jq '.name') = $(__jq '.name') ]] && continue 2 # offline transaction already witnessed by this signing key
                    done

                    skey_path=""
                    # look for signing key in wallet folder
                    while IFS= read -r -d '' w_file; do
                      if [[ ${w_file} = */"${WALLET_PAY_SK_FILENAME}" || ${w_file} = */"${WALLET_STAKE_SK_FILENAME}" ]]; then
                        ! ${CCLI} key verification-key --signing-key-file "${w_file}" --verification-key-file "${TMP_DIR}"/tmp.vkey && continue
                        if [[ $(jq -er '.type' "${w_file}" 2>/dev/null) = *"Extended"* ]]; then
                          ! ${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/tmp.vkey" --verification-key-file "${TMP_DIR}/tmp2.vkey" && continue
                          mv -f "${TMP_DIR}/tmp2.vkey" "${TMP_DIR}/tmp.vkey"
                        fi
                        grep -q "${otx_vkey_cborHex}" "${TMP_DIR}"/tmp.vkey && skey_path="${w_file}" && break
                      elif [[ ${w_file} = */"${WALLET_HW_PAY_SK_FILENAME}" || ${w_file} = */"${WALLET_HW_STAKE_SK_FILENAME}" ]]; then
                        grep -q "${otx_vkey_cborHex:4}" "${w_file}" && skey_path="${w_file}" && break # strip 5820 prefix
                      fi
                    done < <(find "${WALLET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -print0 2>/dev/null)
                    # look for cold signing key in pool folder
                    if [[ -z ${skey_path} ]]; then
                      while IFS= read -r -d '' p_file; do
                        ! ${CCLI} key verification-key --signing-key-file "${p_file}" --verification-key-file "${TMP_DIR}"/tmp.vkey && continue
                        grep -q "${otx_vkey_cborHex}" "${TMP_DIR}"/tmp.vkey && skey_path="${p_file}" && break
                      done < <(find "${POOL_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${POOL_COLDKEY_SK_FILENAME}" -print0 2>/dev/null)
                    fi

                    if [[ -n ${skey_path} ]]; then
                      println DEBUG "\nFound a match for ${otx_signing_name}, use this file ? : ${FG_LGRAY}${skey_path}${NC}"
                      select_opt "[y] Yes" "[n] No, continue with manual selection" "[s] Skip"
                      case $? in
                        0)  if ! witnessTx "${TMP_DIR}/tx.raw" "${skey_path}"; then waitForInput && continue 2; fi
                            if ! offlineJSON=$(jq ".witness += [{ name: \"${otx_signing_name}\", witnessBody: $(jq -c . "${tx_witness_files[0]}") }]" <<< ${offlineJSON}); then return 1; fi
                            jq -r . <<< "${offlineJSON}" > "${offline_tx}" # save this witness to disk
                            continue ;;
                        1)  selection=0 ;;
                        2)  continue ;;
                      esac
                    else
                      println DEBUG "\nDo you want to sign ${otx_type} with: ${FG_LGRAY}${otx_signing_name}${NC} ?"
                      select_opt "[y] Yes" "[s] Skip"
                      selection=$?
                    fi

                    case ${selection} in
                      0) [[ ${otx_signing_name} = "Pool "* ]] && dialog_start_path="${POOL_FOLDER}" || dialog_start_path="${WALLET_FOLDER}"
                          fileDialog "Enter path to ${otx_signing_name}" "${dialog_start_path}/"
                          [[ ! -f "${file}" ]] && println ERROR "${FG_RED}ERROR${NC}: file not found: ${file}" && waitForInput && continue 2
                          if [[ $(jq -r '.description' "${file}") = *"Hardware"* ]]; then
                            if ! grep -q "${otx_vkey_cborHex:4}" "${file}"; then # strip 5820 prefix
                              println ERROR "${FG_RED}ERROR${NC}: signing key provided doesn't match with verification key in offline transaction for: ${otx_signing_name}"
                              println ERROR "Provided hardware signing key's verification cborXPubKeyHex: $(jq -r .cborXPubKeyHex "${file}")"
                              println ERROR "Transaction verification cborHex: ${otx_vkey_cborHex:4}"
                              waitForInput && continue 2
                            fi
                          else
                            println ACTION "${CCLI} key verification-key --signing-key-file ${file} --verification-key-file ${TMP_DIR}/tmp.vkey"
                            if ! ${CCLI} key verification-key --signing-key-file "${file}" --verification-key-file "${TMP_DIR}"/tmp.vkey; then waitForInput && continue 2; fi
                            if [[ $(jq -r '.type' "${file}") = *"Extended"* ]]; then
                              println ACTION "${CCLI} key non-extended-key --extended-verification-key-file ${TMP_DIR}/tmp.vkey --verification-key-file ${TMP_DIR}/tmp2.vkey"
                              if ! ${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/tmp.vkey" --verification-key-file "${TMP_DIR}/tmp2.vkey"; then waitForInput && continue 2; fi
                              mv -f "${TMP_DIR}/tmp2.vkey" "${TMP_DIR}/tmp.vkey"
                            fi
                            if [[ ${otx_vkey_cborHex} != $(jq -r .cborHex "${TMP_DIR}"/tmp.vkey) ]]; then
                              println ERROR "${FG_RED}ERROR${NC}: signing key provided doesn't match with verification key in offline transaction for: ${otx_signing_name}"
                              println ERROR "Provided signing key's verification cborHex: $(jq -r .cborHex "${TMP_DIR}"/tmp.vkey)"
                              println ERROR "Transaction verification cborHex: ${otx_vkey_cborHex}"
                              waitForInput && continue 2
                            fi
                          fi
                          if ! witnessTx "${TMP_DIR}/tx.raw" "${file}"; then waitForInput && continue 2; fi
                          if ! offlineJSON=$(jq ".witness += [{ name: \"${otx_signing_name}\", witnessBody: $(jq -c . "${tx_witness_files[0]}") }]" <<< ${offlineJSON}); then return 1; fi
                          jq -r . <<< "${offlineJSON}" > "${offline_tx}" # save this witness to disk
                          ;;
                      1)  continue ;;
                    esac
                  done
                  echo
                  if [[ $(jq -r '."signing-file" | length' <<< "${offlineJSON}") -eq $(jq -r '.witness | length' <<< "${offlineJSON}") ]]; then # witnessed by all signing keys
                    tx_witness_files=()
                    for otx_witness in $(jq -r '.witness[] | @base64' <<< "${offlineJSON}"); do
                      _jq() { base64 -d <<< ${otx_witness} | jq -r "${1}"; }
                      tx_witness="$(mktemp "${TMP_DIR}/tx.witness_XXXXXXXXXX")"
                      jq -r . <<< "$(_jq '.witnessBody')" > "${tx_witness}"
                      tx_witness_files+=( "${tx_witness}" )
                    done
                    if ! assembleTx "${TMP_DIR}/tx.raw"; then waitForInput && continue; fi
                    if jq ". += { \"signed-txBody\": $(jq -c . "${tx_signed}") }" <<< "${offlineJSON}" > "${offline_tx}"; then
                      println "Offline transaction successfully assembled and signed by all signing keys"
                      println "please move ${offline_tx} back to online node and submit before ${FG_LGRAY}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}!"
                    else
                      println ERROR "${FG_RED}ERROR${NC}: failed to write signed tx body to offline transaction file!"
                    fi
                  else
                    println "Offline transaction need to be signed by ${FG_LBLUE}$(jq -r '."signing-file" | length' <<< "${offlineJSON}")${NC} signing keys, signed by ${FG_LBLUE}$(jq -r '.witness | length' <<< "${offlineJSON}")${NC} so far!"
                  fi
                  ;;
                *) println ERROR "${FG_RED}ERROR${NC}: unsupported offline tx type: ${otx_type}" && waitForInput && continue ;;
              esac
              waitForInput && continue
              ;; ###################################################################
            submit)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> TRANSACTION >> SUBMIT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitForInput && continue
              fi
              echo
              fileDialog "Enter path to offline tx file to submit" "${TMP_DIR}/" && echo
              offline_tx=${file}
              [[ -z "${offline_tx}" ]] && continue
              if [[ ! -f "${offline_tx}" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: file not found: ${offline_tx}"
                waitForInput && continue
              elif ! offlineJSON=$(jq -erc . "${offline_tx}"); then
                println ERROR "${FG_RED}ERROR${NC}: invalid JSON file: ${offline_tx}"
                waitForInput && continue
              fi
              if ! otx_type=$(jq -er '.type' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'type' not found in: ${offline_tx}" && waitForInput && continue; fi
              if ! otx_date_created=$(jq -er '."date-created"' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'date-created' not found in: ${offline_tx}" && waitForInput && continue; fi
              if ! otx_date_expire=$(jq -er '."date-expire"' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'date-expire' not found in: ${offline_tx}" && waitForInput && continue; fi
              if ! otx_txFee=$(jq -er '.txFee' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'txFee' not found in: ${offline_tx}" && waitForInput && continue; fi
              if ! otx_signed_txBody=$(jq -er '."signed-txBody"' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'signed-txBody' not found in: ${offline_tx}" && waitForInput && continue; fi
              [[ $(jq 'length' <<< ${otx_signed_txBody}) -eq 0 ]] && println ERROR "${FG_RED}ERROR${NC}: transaction not signed, please sign transaction first!" && waitForInput && continue
              println DEBUG "Transaction type : ${FG_YELLOW}${otx_type}${NC}"
              if jq -er '."wallet-name"' &>/dev/null <<< ${offlineJSON}; then 
                println DEBUG "Transaction fee  : ${FG_LBLUE}$(formatLovelace ${otx_txFee})${NC} Ada, payed by ${FG_GREEN}$(jq -r '."wallet-name"' <<< ${offlineJSON})${NC}"
              else
                println DEBUG "Transaction fee  : ${FG_LBLUE}$(formatLovelace ${otx_txFee})${NC} Ada"
              fi
              println DEBUG "Created          : ${FG_LGRAY}$(date '+%F %T %Z' --date="${otx_date_created}")${NC}"
              if [[ $(date '+%s' --date="${otx_date_expire}") -lt $(date '+%s') ]]; then
                println DEBUG "Expire           : ${FG_RED}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}"
                println ERROR "\n${FG_RED}ERROR${NC}: offline transaction expired!  please create a new one with long enough Time To Live (TTL)"
                waitForInput && continue
              else
                println DEBUG "Expire           : ${FG_LGRAY}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}"
              fi
              case "${otx_type}" in
                "Wallet Registration"|"Wallet De-Registration"|"Payment"|"Wallet Delegation"|"Wallet Rewards Withdrawal"|"Pool De-Registration"|"Metadata"|"Pool Registration"|"Pool Update"|"Asset Minting"|"Asset Burning"|"Poll Cast")
                  echo
                  [[ ${otx_type} = "Wallet De-Registration" ]] && println DEBUG "Amount returned  : ${FG_LBLUE}$(formatLovelace "$(jq -r '."amount-returned"' <<< ${offlineJSON})")${NC} Ada"
                  if [[ ${otx_type} = "Payment" ]]; then
                    println DEBUG "Source addr      : ${FG_LGRAY}$(jq -r '."source-address"' <<< ${offlineJSON})${NC}"
                    println DEBUG "Destination addr : ${FG_LGRAY}$(jq -r '."destination-address"' <<< ${offlineJSON})${NC}"
                    println DEBUG "Amount           : ${FG_LBLUE}$(formatLovelace "$(jq -r '.assets[] | select(.asset=="lovelace") | .amount' <<< ${offlineJSON})")${NC} ${FG_GREEN}Ada${NC}"
                    for otx_assets in $(jq -r '.assets[] | @base64' <<< "${offlineJSON}"); do
                      _jq() { base64 -d <<< ${otx_assets} | jq -r "${1}"; }
                      otx_asset=$(_jq '.asset')
                      [[ ${otx_asset} = "lovelace" ]] && continue
                      println DEBUG "                   ${FG_LBLUE}$(formatAsset "$(_jq '.amount')")${NC} ${FG_LGRAY}${otx_asset}${NC}"
                    done
                  fi
                  [[ ${otx_type} = "Wallet Rewards Withdrawal" ]] && println DEBUG "Rewards          : ${FG_LBLUE}$(formatLovelace "$(jq -r '.rewards' <<< ${offlineJSON})")${NC} Ada"
                  jq -er '."pool-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Pool ID          : ${FG_LGRAY}$(jq -r '."pool-id"' <<< ${offlineJSON})${NC}"
                  if jq -er '."pool-name"' <<< ${offlineJSON} &>/dev/null; then
                    [[ ${otx_type} != "Pool Registration" ]] && println DEBUG "Pool name        : ${FG_LGRAY}$(jq -r '."pool-name"' <<< ${offlineJSON})${NC}"
                  fi
                  [[ ${otx_type} = "Pool De-Registration" ]] && println DEBUG "Ticker           : ${FG_LGRAY}$(jq -r '."pool-ticker"' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Pool De-Registration" ]] && println DEBUG "To be retired    : epoch ${FG_LGRAY}$(jq -r '."retire-epoch"' <<< ${offlineJSON})${NC}"
                  jq -er '.metadata' <<< ${offlineJSON} &>/dev/null && println DEBUG "Metadata         :\n$(jq -r '.metadata' <<< ${offlineJSON})\n"
                  [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Pool name        : ${FG_LGRAY}$(jq -r '."pool-metadata".name' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Ticker           : ${FG_LGRAY}$(jq -r '."pool-metadata".ticker' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Pledge           : ${FG_LBLUE}$(formatLovelace "$(AdaToLovelace "$(jq -r '."pool-pledge"' <<< ${offlineJSON})")")${NC} Ada"
                  [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Margin           : ${FG_LBLUE}$(jq -r '."pool-margin"' <<< ${offlineJSON})${NC} %"
                  [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Cost             : ${FG_LBLUE}$(formatLovelace "$(AdaToLovelace "$(jq -r '."pool-cost"' <<< ${offlineJSON})")")${NC} Ada"
                  [[ ${otx_type} = "Asset Minting" || ${otx_type} = "Asset Burning" ]] && println DEBUG "Policy Name      : ${FG_LGRAY}$(jq -r '."policy-name"' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Asset Minting" || ${otx_type} = "Asset Burning" ]] && println DEBUG "Policy ID        : ${FG_LGRAY}$(jq -r '."policy-id"' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Asset Minting" || ${otx_type} = "Asset Burning" ]] && println DEBUG "Asset Name       : ${FG_LGRAY}$(jq -r '."asset-name"' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Asset Minting" ]] && println DEBUG "Assets To Mint   : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-amount"' <<< ${offlineJSON})")${NC}"
                  [[ ${otx_type} = "Asset Minting" ]] && println DEBUG "Assets Minted    : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-minted"' <<< ${offlineJSON})")${NC}"
                  [[ ${otx_type} = "Asset Burning" ]] && println DEBUG "Assets To Burn   : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-amount"' <<< ${offlineJSON})")${NC}"
                  [[ ${otx_type} = "Asset Burning" ]] && println DEBUG "Assets Left      : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-minted"' <<< ${offlineJSON})")${NC}"
                  if [[ ${otx_type} = "Asset Minting" || ${otx_type} = "Asset Burning" ]] && otx_metadata=$(jq -er '.metadata' <<< ${offlineJSON}); then println DEBUG "Metadata         : \n${otx_metadata}\n"; fi
                  [[ ${otx_type} = "Poll Cast" ]] && println DEBUG "Poll ID          : ${FG_LGRAY}$(jq -r '."poll-txId"' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Poll Cast" ]] && println DEBUG "Title            : ${FG_LGRAY}$(jq -r '."poll-title"' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Poll Cast" ]] && println DEBUG "Question         : ${FG_LGRAY}$(jq -r '."poll-question"' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Poll Cast" ]] && println DEBUG "Answer           : ${FG_LGRAY}$(jq -r '."poll-answer"' <<< ${offlineJSON})${NC}"
                  tx_signed="${TMP_DIR}/tx.signed_$(date +%s)"
                  println DEBUG "\nProceed to submit transaction?"
                  select_opt "[y] Yes" "[n] No"
                  case $? in
                    0) : ;;
                    1) continue ;;
                  esac
                  echo -e "${otx_signed_txBody}" > "${tx_signed}"
                  if ! submitTx "${tx_signed}"; then waitForInput && continue; fi
                  if [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]]; then
                    if otx_pool_name=$(jq -er '."pool-name"' <<< ${offlineJSON}); then
                      if ! jq '."pool-reg-cert"' <<< "${offlineJSON}" > "${POOL_FOLDER}/${otx_pool_name}/${POOL_REGCERT_FILENAME}"; then println ERROR "${FG_RED}ERROR${NC}: failed to write pool cert to disk"; fi
                      [[ -f "${POOL_FOLDER}/${otx_pool_name}/${POOL_DEREGCERT_FILENAME}" ]] && rm -f "${POOL_FOLDER}/${otx_pool_name}/${POOL_DEREGCERT_FILENAME}" # delete de-registration cert if available
                    else
                      println ERROR "${FG_RED}ERROR${NC}: field 'pool-name' not found in: ${offline_tx}"
                    fi
                  fi
                  echo
                  println "Offline transaction successfully submitted and set to be included in next block!"
                  echo 
                  println DEBUG "Delete submitted offline transaction file?"
                  select_opt "[y] Yes" "[n] No"
                  case $? in
                    0) rm -f "${offline_tx}" ;;
                    1) : ;;
                  esac
                  ;;
                *) println ERROR "${FG_RED}ERROR${NC}: unsupported offline tx type: ${otx_type}" && waitForInput && continue ;;
              esac
              waitForInput && continue
              ;; ###################################################################
          esac # transaction sub OPERATION
        done # Transaction loop
        ;; ###################################################################
      blocks)
        clear
        println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        println " >> BLOCKS"
        println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        if ! command -v sqlite3 >/dev/null; then
          println ERROR "${FG_RED}ERROR${NC}: sqlite3 not found!"
          waitForInput && continue
        fi
        current_epoch=$(getEpoch)
        println DEBUG "Current epoch: ${FG_LBLUE}${current_epoch}${NC}\n"
        println DEBUG "Show a block summary for all epochs or a detailed view for a specific epoch?"
        select_opt "[s] Summary" "[e] Epoch" "[Esc] Cancel"
        case $? in
          0) getAnswerAnyCust epoch_enter "Enter number of epochs to show (enter for 10)"
             epoch_enter=${epoch_enter:-10}
             if ! isNumber ${epoch_enter}; then
               println ERROR "\n${FG_RED}ERROR${NC}: not a number"
               waitForInput && continue
             fi
             view=1; view_output="${FG_YELLOW}[b] Block View${NC} | [i] Info"
             while true; do
               clear
               println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
               println " >> BLOCKS"
               println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
               current_epoch=$(getEpoch)
               println DEBUG "Current epoch: ${FG_LBLUE}${current_epoch}${NC}\n"
               if [[ ${view} -eq 1 ]]; then
                 [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=$((current_epoch+1)) LIMIT 1);" 2>/dev/null) -eq 1 ]] && ((current_epoch++))
                 first_epoch=$(( current_epoch - epoch_enter ))
                 [[ ${first_epoch} -lt 0 ]] && first_epoch=0
                 ideal_len=$(sqlite3 "${BLOCKLOG_DB}" "SELECT LENGTH(epoch_slots_ideal) FROM epochdata WHERE epoch BETWEEN ${first_epoch} and ${current_epoch} ORDER BY LENGTH(epoch_slots_ideal) DESC LIMIT 1;")
                 [[ ${ideal_len} -lt 5 ]] && ideal_len=5
                 luck_len=$(sqlite3 "${BLOCKLOG_DB}" "SELECT LENGTH(max_performance) FROM epochdata WHERE epoch BETWEEN ${first_epoch} and ${current_epoch} ORDER BY LENGTH(max_performance) DESC LIMIT 1;")
                 [[ $((luck_len+1)) -le 4 ]] && luck_len=4 || luck_len=$((luck_len+1))
                 printf '|' >&3; printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" | tr " " "=" >&3; printf '|\n' >&3
                 printf "| %-5s | %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_LBLUE}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "Epoch" "Leader" "Ideal" "Luck" "Adopted" "Confirmed" "Missed" "Ghosted" "Stolen" "Invalid" >&3
                 printf '|' >&3; printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" | tr " " "=" >&3; printf '|\n' >&3
                 while [[ ${current_epoch} -gt ${first_epoch} ]]; do
                   invalid_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='invalid';" 2>/dev/null)
                   missed_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='missed';" 2>/dev/null)
                   ghosted_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='ghosted';" 2>/dev/null)
                   stolen_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='stolen';" 2>/dev/null)
                   confirmed_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='confirmed';" 2>/dev/null)
                   adopted_cnt=$(( $(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='adopted';" 2>/dev/null) + confirmed_cnt ))
                   leader_cnt=$(( $(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='leader';" 2>/dev/null) + adopted_cnt + invalid_cnt + missed_cnt + ghosted_cnt + stolen_cnt ))
                   IFS='|' && read -ra epoch_stats <<< "$(sqlite3 "${BLOCKLOG_DB}" "SELECT epoch_slots_ideal, max_performance FROM epochdata WHERE epoch=${current_epoch};" 2>/dev/null)" && IFS=' '
                   if [[ ${#epoch_stats[@]} -eq 0 ]]; then
                     epoch_stats=("-" "-")
                   else
                     epoch_stats[1]="${epoch_stats[1]}%"
                   fi
                   printf "| ${FG_LGRAY}%-5s${NC} | ${FG_LGRAY}%-6s${NC} | ${FG_LGRAY}%-${ideal_len}s${NC} | ${FG_LGRAY}%-${luck_len}s${NC} | ${FG_LBLUE}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "${current_epoch}" "${leader_cnt}" "${epoch_stats[0]}" "${epoch_stats[1]}" "${adopted_cnt}" "${confirmed_cnt}" "${missed_cnt}" "${ghosted_cnt}" "${stolen_cnt}" "${invalid_cnt}" >&3
                   ((current_epoch--))
                 done
                 printf '|' >&3; printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" | tr " " "=" >&3; printf '|\n' >&3
               else
                 println OFF "Block Status:\n"
                 println OFF "Leader    - Scheduled to make block at this slot"
                 println OFF "Ideal     - Expected/Ideal number of blocks assigned based on active stake (sigma)"
                 println OFF "Luck      - Leader slots assigned vs Ideal slots for this epoch"
                 println OFF "Adopted   - Block created successfully"
                 println OFF "Confirmed - Block created validated to be on-chain with the certainty"
                 println OFF "            set in 'cncli.sh' for 'CONFIRM_BLOCK_CNT'"
                 println OFF "Missed    - Scheduled at slot but no record of it in cncli DB and no"
                 println OFF "            other pool has made a block for this slot"
                 println OFF "Ghosted   - Block created but marked as orphaned and no other pool has made"
                 println OFF "            a valid block for this slot, height battle or block propagation issue"
                 println OFF "Stolen    - Another pool has a valid block registered on-chain for the same slot"
                 println OFF "Invalid   - Pool failed to create block, base64 encoded error message"
                 println OFF "            can be decoded with 'echo <base64 hash> | base64 -d | jq -r'"
               fi
               echo
               println OFF "[h] Home | ${view_output} | [*] Refresh"
               read -rsn1 key
               case ${key} in
                 h ) continue 2 ;;
                 b ) view=1; view_output="${FG_YELLOW}[b] Block View${NC} | [i] Info" ;;
                 i ) view=2; view_output="[b] Block View | ${FG_YELLOW}[i] Info${NC}" ;;
                 * ) continue ;;
               esac
             done
             ;;
          1) [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=$((current_epoch+1)) LIMIT 1);" 2>/dev/null) -eq 1 ]] && println DEBUG "\n${FG_YELLOW}Leader schedule for next epoch[$((current_epoch+1))] available${NC}"
             echo && getAnswerAnyCust epoch_enter "Enter epoch to list (enter for current)"
             [[ -z "${epoch_enter}" ]] && epoch_enter=${current_epoch}
             if [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=${epoch_enter} LIMIT 1);" 2>/dev/null) -eq 0 ]]; then
               println "No blocks in epoch ${epoch_enter}"
               waitForInput && continue
             fi
             view=1; view_output="${FG_YELLOW}[1] View 1${NC} | [2] View 2 | [3] View 3 | [i] Info"
             while true; do
               clear
               println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
               println " >> BLOCKS"
               println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
               current_epoch=$(getEpoch)
               println DEBUG "Current epoch  : ${FG_LBLUE}${current_epoch}${NC}"
               println DEBUG "Selected epoch : ${FG_LBLUE}${epoch_enter}${NC}\n"
               invalid_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epoch_enter} AND status='invalid';" 2>/dev/null)
               missed_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epoch_enter} AND status='missed';" 2>/dev/null)
               ghosted_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epoch_enter} AND status='ghosted';" 2>/dev/null)
               stolen_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epoch_enter} AND status='stolen';" 2>/dev/null)
               confirmed_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epoch_enter} AND status='confirmed';" 2>/dev/null)
               adopted_cnt=$(( $(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epoch_enter} AND status='adopted';" 2>/dev/null) + confirmed_cnt ))
               leader_cnt=$(( $(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epoch_enter} AND status='leader';" 2>/dev/null) + adopted_cnt + invalid_cnt + missed_cnt + ghosted_cnt + stolen_cnt ))
               IFS='|' && read -ra epoch_stats <<< "$(sqlite3 "${BLOCKLOG_DB}" "SELECT epoch_slots_ideal, max_performance FROM epochdata WHERE epoch=${epoch_enter};" 2>/dev/null)" && IFS=' '
               if [[ ${#epoch_stats[@]} -eq 0 ]]; then
                 epoch_stats=("-" "-")
               else
                 epoch_stats[1]="${epoch_stats[1]}%"
               fi
               [[ ${#epoch_stats[0]} -gt 5 ]] && ideal_len=${#epoch_stats[0]} || ideal_len=5
               [[ ${#epoch_stats[1]} -gt 4 ]] && luck_len=${#epoch_stats[1]} || luck_len=4
               printf '|' >&3; printf "%$((6+ideal_len+luck_len+7+9+6+7+6+7+24+2))s" | tr " " "=" >&3; printf '|\n' >&3
               printf "| %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_LBLUE}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "Leader" "Ideal" "Luck" "Adopted" "Confirmed" "Missed" "Ghosted" "Stolen" "Invalid" >&3
               printf '|' >&3; printf "%$((6+ideal_len+luck_len+7+9+6+7+6+7+24+2))s" | tr " " "=" >&3; printf '|\n' >&3
               printf "| ${FG_LGRAY}%-6s${NC} | ${FG_LGRAY}%-${ideal_len}s${NC} | ${FG_LGRAY}%-${luck_len}s${NC} | ${FG_LBLUE}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "${leader_cnt}" "${epoch_stats[0]}" "${epoch_stats[1]}" "${adopted_cnt}" "${confirmed_cnt}" "${missed_cnt}" "${ghosted_cnt}" "${stolen_cnt}" "${invalid_cnt}" >&3
               printf '|' >&3; printf "%$((6+ideal_len+luck_len+7+9+6+7+6+7+24+2))s" | tr " " "=" >&3; printf '|\n' >&3
               echo
               # print block table
               block_cnt=1
               status_len=$(sqlite3 "${BLOCKLOG_DB}" "SELECT LENGTH(status) FROM blocklog WHERE epoch=${epoch_enter} ORDER BY LENGTH(status) DESC LIMIT 1;")
               [[ ${status_len} -lt 6 ]] && status_len=6
               block_len=$(sqlite3 "${BLOCKLOG_DB}" "SELECT LENGTH(block) FROM blocklog WHERE epoch=${epoch_enter} ORDER BY LENGTH(slot) DESC LIMIT 1;")
               [[ ${block_len} -lt 5 ]] && block_len=5
               slot_len=$(sqlite3 "${BLOCKLOG_DB}" "SELECT LENGTH(slot) FROM blocklog WHERE epoch=${epoch_enter} ORDER BY LENGTH(slot) DESC LIMIT 1;")
               [[ ${slot_len} -lt 4 ]] && slot_len=4
               slot_in_epoch_len=$(sqlite3 "${BLOCKLOG_DB}" "SELECT LENGTH(slot_in_epoch) FROM blocklog WHERE epoch=${epoch_enter} ORDER BY LENGTH(slot_in_epoch) DESC LIMIT 1;")
               [[ ${slot_in_epoch_len} -lt 11 ]] && slot_in_epoch_len=11
               at_len=24
               size_len=$(sqlite3 "${BLOCKLOG_DB}" "SELECT LENGTH(size) FROM blocklog WHERE epoch=${epoch_enter} ORDER BY LENGTH(size) DESC LIMIT 1;")
               [[ ${size_len} -lt 4 ]] && size_len=4
               hash_len=$(sqlite3 "${BLOCKLOG_DB}" "SELECT LENGTH(hash) FROM blocklog WHERE epoch=${epoch_enter} ORDER BY LENGTH(hash) DESC LIMIT 1;")
               [[ ${hash_len} -lt 4 ]] && hash_len=4
               if [[ ${view} -eq 1 ]]; then
                 printf '|' >&3; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+17))s" | tr " " "=" >&3; printf '|\n' >&3
                 printf "| %-${#leader_cnt}s | %-${status_len}s | %-${block_len}s | %-${slot_len}s | %-${slot_in_epoch_len}s | %-${at_len}s |\n" "#" "Status" "Block" "Slot" "SlotInEpoch" "Scheduled At" >&3
                 printf '|' >&3; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+17))s" | tr " " "=" >&3; printf '|\n' >&3
                 while IFS='|' read -r status block slot slot_in_epoch at; do
                   at=$(TZ="${BLOCKLOG_TZ}" date '+%F %T %Z' --date="${at}")
                   [[ ${block} -eq 0 ]] && block="-"
                   printf "| ${FG_LGRAY}%-${#leader_cnt}s${NC} | ${FG_LGRAY}%-${status_len}s${NC} | ${FG_LGRAY}%-${block_len}s${NC} | ${FG_LGRAY}%-${slot_len}s${NC} | ${FG_LGRAY}%-${slot_in_epoch_len}s${NC} | ${FG_LGRAY}%-${at_len}s${NC} |\n" "${block_cnt}" "${status}" "${block}" "${slot}" "${slot_in_epoch}" "${at}" >&3
                   ((block_cnt++))
                 done < <(sqlite3 "${BLOCKLOG_DB}" "SELECT status, block, slot, slot_in_epoch, at FROM blocklog WHERE epoch=${epoch_enter} ORDER BY slot;" 2>/dev/null)
                 printf '|' >&3; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+17))s" | tr " " "=" >&3; printf '|\n' >&3
               elif [[ ${view} -eq 2 ]]; then
                 printf '|' >&3; printf "%$((${#leader_cnt}+status_len+slot_len+size_len+hash_len+14))s" | tr " " "=" >&3; printf '|\n' >&3
                 printf "| %-${#leader_cnt}s | %-${status_len}s | %-${slot_len}s | %-${size_len}s | %-${hash_len}s |\n" "#" "Status" "Slot" "Size" "Hash" >&3
                 printf '|' >&3; printf "%$((${#leader_cnt}+status_len+slot_len+size_len+hash_len+14))s" | tr " " "=" >&3; printf '|\n' >&3
                 while IFS='|' read -r status slot size hash; do
                   [[ ${size} -eq 0 ]] && size="-"
                   [[ -z ${hash} ]] && hash="-"
                   printf "| ${FG_LGRAY}%-${#leader_cnt}s${NC} | ${FG_LGRAY}%-${status_len}s${NC} | ${FG_LGRAY}%-${slot_len}s${NC} | ${FG_LGRAY}%-${size_len}s${NC} | ${FG_LGRAY}%-${hash_len}s${NC} |\n" "${block_cnt}" "${status}" "${slot}" "${size}" "${hash}" >&3
                   ((block_cnt++))
                 done < <(sqlite3 "${BLOCKLOG_DB}" "SELECT status, slot, size, hash FROM blocklog WHERE epoch=${epoch_enter} ORDER BY slot;" 2>/dev/null)
                 printf '|' >&3; printf "%$((${#leader_cnt}+status_len+slot_len+size_len+hash_len+14))s" | tr " " "=" >&3; printf '|\n' >&3
               elif [[ ${view} -eq 3 ]]; then
                 printf '|' >&3; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+size_len+hash_len+23))s" | tr " " "=" >&3; printf '|\n' >&3
                 printf "| %-${#leader_cnt}s | %-${status_len}s | %-${block_len}s | %-${slot_len}s | %-${slot_in_epoch_len}s | %-${at_len}s | %-${size_len}s | %-${hash_len}s |\n" "#" "Status" "Block" "Slot" "SlotInEpoch" "Scheduled At" "Size" "Hash" >&3
                 printf '|' >&3; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+size_len+hash_len+23))s" | tr " " "=" >&3; printf '|\n' >&3
                 while IFS='|' read -r status block slot slot_in_epoch at size hash; do
                   at=$(TZ="${BLOCKLOG_TZ}" date '+%F %T %Z' --date="${at}")
                   [[ ${block} -eq 0 ]] && block="-"
                   [[ ${size} -eq 0 ]] && size="-"
                   [[ -z ${hash} ]] && hash="-"
                   printf "| ${FG_LGRAY}%-${#leader_cnt}s${NC} | ${FG_LGRAY}%-${status_len}s${NC} | ${FG_LGRAY}%-${block_len}s${NC} | ${FG_LGRAY}%-${slot_len}s${NC} | ${FG_LGRAY}%-${slot_in_epoch_len}s${NC} | ${FG_LGRAY}%-${at_len}s${NC} | ${FG_LGRAY}%-${size_len}s${NC} | ${FG_LGRAY}%-${hash_len}s${NC} |\n" "${block_cnt}" "${status}" "${block}" "${slot}" "${slot_in_epoch}" "${at}" "${size}" "${hash}" >&3
                   ((block_cnt++))
                 done < <(sqlite3 "${BLOCKLOG_DB}" "SELECT status, block, slot, slot_in_epoch, at, size, hash FROM blocklog WHERE epoch=${epoch_enter} ORDER BY slot;" 2>/dev/null)
                 printf '|' >&3; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+size_len+hash_len+23))s" | tr " " "=" >&3; printf '|\n' >&3
               elif [[ ${view} -eq 4 ]]; then
                 println OFF "Block Status:\n"
                 println OFF "Leader    - Scheduled to make block at this slot"
                 println OFF "Ideal     - Expected/Ideal number of blocks assigned based on active stake (sigma)"
                 println OFF "Luck      - Leader slots assigned vs Ideal slots for this epoch"
                 println OFF "Adopted   - Block created successfully"
                 println OFF "Confirmed - Block created validated to be on-chain with the certainty"
                 println OFF "            set in 'cncli.sh' for 'CONFIRM_BLOCK_CNT'"
                 println OFF "Missed    - Scheduled at slot but no record of it in cncli DB and no"
                 println OFF "            other pool has made a block for this slot"
                 println OFF "Ghosted   - Block created but marked as orphaned and no other pool has made"
                 println OFF "            a valid block for this slot, height battle or block propagation issue"
                 println OFF "Stolen    - Another pool has a valid block registered on-chain for the same slot"
                 println OFF "Invalid   - Pool failed to create block, base64 encoded error message"
                 println OFF "            can be decoded with 'echo <base64 hash> | base64 -d | jq -r'"
               fi
               echo
               println OFF "[h] Home | ${view_output} | [*] Refresh"
               read -rsn1 key
               case ${key} in
                 h ) continue 2 ;;
                 1 ) view=1; view_output="${FG_YELLOW}[1] View 1${NC} | [2] View 2 | [3] View 3 | [i] Info" ;;
                 2 ) view=2; view_output="[1] View 1 | ${FG_YELLOW}[2] View 2${NC} | [3] View 3 | [i] Info" ;;
                 3 ) view=3; view_output="[1] View 1 | [2] View 2 | ${FG_YELLOW}[3] View 3${NC} | [i] Info" ;;
                 i ) view=4; view_output="[1] View 1 | [2] View 2 | [3] View 3 | ${FG_YELLOW}[i] Info${NC}" ;;
                 * ) continue ;;
               esac
             done
             ;;
          2) continue ;;
        esac
        waitForInput && continue
        ;; ###################################################################
      backup)
        clear
        println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        println " >> BACKUP & RESTORE"
        println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        echo
        println DEBUG "Create or restore a backup of CNTools wallets & pools"
        echo
        println DEBUG "Backup or Restore?"
        select_opt "[b] Backup" "[r] Restore" "[Esc] Cancel"
        case $? in
          0) echo
            dirDialog "Enter backup destination directory (created if non existent)" && echo
            [[ "${dir}" != */ ]] && backup_path="${dir}/" || backup_path="${dir}"
            if [[ ! "${backup_path}" =~ ^/[-0-9A-Za-z_]+ ]]; then
              println ERROR "${FG_RED}ERROR${NC}: invalid path, please specify the full path to backup directory (space not allowed)"
              waitForInput && continue
            fi
            if ! mkdir -p "${backup_path}"; then println ERROR "${FG_RED}ERROR${NC}: failed to create backup directory:\n${backup_path}" && waitForInput && continue; fi
            missing_keys="false"
            excluded_files=()
            [[ -d "${ASSET_FOLDER}" ]] && asset_out=" and asset ${ASSET_POLICY_SK_FILENAME}" || asset_out=""
            println DEBUG "Include private keys in backup?"
            println DEBUG "- No  > create a backup excluding wallets ${WALLET_PAY_SK_FILENAME}/${WALLET_STAKE_SK_FILENAME}, pools ${POOL_COLDKEY_SK_FILENAME}${asset_out}"
            println DEBUG "- Yes > create a backup including all available files"
            select_opt "[n] No" "[y] Yes"
            case $? in
              0) excluded_files=(
                   --exclude=${WALLET_PAY_SK_FILENAME}
                   --exclude=${WALLET_PAY_SK_FILENAME}.gpg
                   --exclude=${WALLET_STAKE_SK_FILENAME}
                   --exclude=${WALLET_STAKE_SK_FILENAME}.gpg
                   --exclude=${POOL_COLDKEY_SK_FILENAME}
                   --exclude=${POOL_COLDKEY_SK_FILENAME}.gpg
                   --exclude=${ASSET_POLICY_SK_FILENAME}
                   --exclude=${ASSET_POLICY_SK_FILENAME}.gpg
                 )
                 backup_file="${backup_path}online_cntools_backup-$(date '+%Y%m%d%H%M%S').${CNODE_NAME}.tar"
                 ;;
              1) backup_file="${backup_path}offline_cntools_backup-$(date '+%Y%m%d%H%M%S').${CNODE_NAME}.tar" ;;
            esac
            echo
            backup_source=(
              "${WALLET_FOLDER}"
              "${POOL_FOLDER}"
              "${ASSET_FOLDER}"
            )
            backup_list=()
            backup_cnt=0
            println DEBUG "Backup job include:\n"
            for item in "${backup_source[@]}"; do
              [[ ! -d "${item}" ]] && continue
              println DEBUG "$(basename "${item}")"
              while IFS= read -r -d '' dir; do
                backup_list+=( "${dir}" )
                println DEBUG "  ${FG_LGRAY}$(basename "${dir}")${NC}"
                ((backup_cnt++))
              done < <(find "${item}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
            done
            [[ ${backup_cnt} -eq 0 ]] && println "\nNo folders found to include in backup :(" && waitForInput && continue
            echo
            if [[ ${#excluded_files[@]} -gt 0 ]]; then
              println ACTION "tar ${excluded_files[*]} -cf ${backup_file} ${backup_list[*]}"
              if ! output=$(tar "${excluded_files[@]}" -cf "${backup_file}" "${backup_list[@]}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during tarball creation:\n${output}" && waitForInput && continue; fi
              println ACTION "gzip ${backup_file}"
              if ! output=$(gzip "${backup_file}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: gzip error:\n${output}" && waitForInput && continue; fi
              backup_file+=".gz"
            else
              println ACTION "tar -cf ${backup_file} ${backup_list[*]}"
              if ! output=$(tar -cf "${backup_file}" "${backup_list[@]}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during tarball creation:\n${output}" && waitForInput && continue; fi
              println ACTION "gzip ${backup_file}"
              if ! output=$(gzip "${backup_file}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: gzip error:\n${output}" && waitForInput && continue; fi
              backup_file+=".gz"
              while IFS= read -r -d '' wallet; do # check for missing signing keys
                wallet_name=$(basename ${wallet})
                [[ -z "$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f \( -name "${WALLET_PAY_SK_FILENAME}*" -o -name "${WALLET_HW_PAY_SK_FILENAME}" \) -print)" ]] && \
                  println "${FG_YELLOW}WARN${NC}: Wallet ${FG_GREEN}${wallet_name}${NC} missing payment signing key file" && missing_keys="true"
                [[ -z "$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f \( -name "${WALLET_STAKE_SK_FILENAME}*" -o -name "${WALLET_HW_STAKE_SK_FILENAME}" \) -print)" ]] && \
                  println "${FG_YELLOW}WARN${NC}: Wallet ${FG_GREEN}${wallet_name}${NC} missing stake signing key file" && missing_keys="true"
              done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
              while IFS= read -r -d '' pool; do
                pool_name=$(basename ${pool})
                [[ -z "$(find "${pool}" -mindepth 1 -maxdepth 1 -type f -name "${POOL_COLDKEY_SK_FILENAME}*" -print)" ]] && \
                  println "${FG_YELLOW}WARN${NC}: Pool ${FG_GREEN}${pool_name}${NC} missing file ${POOL_COLDKEY_SK_FILENAME}" && missing_keys="true"
              done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
              [[ ${missing_keys} = "true" ]] && echo
            fi
             println DEBUG "Encrypt backup?"
             select_opt "[y] Yes" "[n] No"
             case $? in
               0) echo
                  if getPasswordCust confirm; then # $password variable populated by getPasswordCust function
                    encryptFile "${backup_file}" "${password}"
                    backup_file="${backup_file}.gpg"
                    unset password
                  else
                    println ERROR "\n${FG_RED}ERROR${NC}: password input aborted!"
                  fi
                  ;;
               1) : ;; # do nothing
             esac
             echo
             if [[ ${missing_keys} = "true" ]]; then
               println DEBUG "${FG_YELLOW}There are wallets and/or pools with missing keys.\nIf removed in a previous backup, make sure to keep that master backup safe!${NC}"
               println "\nIncremental backup file ${backup_file} successfully created"
             else
               println "Backup file ${FG_LGRAY}${backup_file}${NC} successfully created"
             fi
             ;;
          1) println DEBUG "\n${FG_BLUE}INFO${NC}: a backup of existing wallet and pool folders will be made before restore is executed\n"
            fileDialog "Enter backup file to restore" && echo
            backup_file=${file}
            if [[ ! -f "${backup_file}" ]]; then
              println ERROR "${FG_RED}ERROR${NC}: file not found: ${backup_file}"
              waitForInput && continue
            fi
            if ! restore_path="$(mktemp -d "${TMP_DIR}/restore_XXXXXXXXXX")"; then println ERROR "${FG_RED}ERROR${NC}: failed to create restore directory:\n${restore_path}" && waitForInput && continue; fi
            tmp_bkp_file=""
            if [ "${backup_file##*.}" = "gpg" ]; then
              println DEBUG "Backup GPG encrypted, enter password to decrypt"
              if getPasswordCust; then # $password variable populated by getPasswordCust function
                tmp_bkp_file=$(mktemp "${TMP_DIR}/bkp_file_XXXXXXXXXX.tar.gz.gpg")
                cp -f "${backup_file}" "${tmp_bkp_file}"
                decryptFile "${backup_file}" "${password}"
                backup_file="${backup_file%.*}"
                unset password
                echo
              else
                println ERROR "\n${FG_RED}ERROR${NC}: password input aborted!"
                waitForInput && continue
              fi
            fi
            println ACTION "tar xfzk ${backup_file} -C ${restore_path}"
            if ! output=$(tar xfzk "${backup_file}" -C "${restore_path}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during tarball extraction:\n${output}" && waitForInput && continue; fi
            [[ -n "${tmp_bkp_file}" ]] && mv -f "${tmp_bkp_file}" "${backup_file}.gpg" && rm -f "${backup_file}" # restore original encrypted backup file
            restore_source=(
              "${restore_path}${WALLET_FOLDER}"
              "${restore_path}${POOL_FOLDER}"
              "${restore_path}${ASSET_FOLDER}"
            )
            restore_list=()
            restore_cnt=0
            println DEBUG "Restore job include:\n"
            for item in "${restore_source[@]}"; do
              [[ ! -d "${item}" ]] && continue
              println DEBUG "$(basename "${item}")"
              while IFS= read -r -d '' dir; do
                restore_list+=( "${dir}" )
                println DEBUG "  ${FG_LGRAY}$(basename "${dir}")${NC}"
                ((restore_cnt++))
              done < <(find "${item}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
            done
            [[ ${restore_cnt} -eq 0 ]] && println "\nNothing in backup file to restore :(" && waitForInput && continue
            echo
            println DEBUG "Continue with restore?"
            select_opt "[n] No" "[y] Yes"
            case $? in
              0) continue ;;
              1) : ;; # do nothing
            esac
            echo
            # Archive/backup existing priv folders
            archive_source=(
              "${WALLET_FOLDER}"
              "${POOL_FOLDER}"
              "${ASSET_FOLDER}"
            )
            archive_list=()
            source_cnt=0
            for item in "${archive_source[@]}"; do
              [[ ! -d "${item}" ]] && continue
              while IFS= read -r -d '' dir; do
                archive_list+=( "${item}" )
                ((source_cnt++))
              done < <(find "${item}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
            done
            if [[ ${source_cnt} -gt 0 ]]; then
              archive_dest="${CNODE_HOME}/priv/archive"
              if ! mkdir -p "${archive_dest}"; then println ERROR "${FG_RED}ERROR${NC}: failed to create archive directory:\n${archive_dest}" && waitForInput && continue; fi
              archive_file="${archive_dest}/archive_$(date '+%Y%m%d%H%M%S').tar.gz"
              println ACTION "tar cfz ${archive_file} ${archive_list[*]}"
              if ! output=$(tar cfz "${archive_file}" "${archive_list[@]}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during archive/backup:\n${output}" && waitForInput && continue; fi
              println DEBUG "An archive of current priv folder has been taken and stored in ${FG_LGRAY}${archive_file}${NC}"
              println DEBUG "Please set a password to GPG encrypt the archive"
              if getPasswordCust confirm; then # $password variable populated by getPasswordCust function
                encryptFile "${archive_file}" "${password}"
                archive_file="${archive_file}.gpg"
                unset password
              else
                println ERROR "\n${FG_RED}ERROR${NC}: password input aborted!"
                println DEBUG "${FG_YELLOW}archive stored unencrypted !!${NC}"
              fi
              echo
            fi
            for item in "${restore_list[@]}"; do
              dest_path="${item:${#restore_path}}"
              while IFS= read -r -d '' file; do # unlock files to make sure restore is successful
                unlockFile "${file}"
              done < <(find "${dest_path}" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
              println ACTION "cp -rf ${item} $(dirname "${dest_path}")"
              cp -rf "${item}" "$(dirname "${dest_path}")"
            done
            println "Backup ${FG_LGRAY}$(basename "${backup_file}")${NC} successfully restored!"
            ;;
          2) continue ;;
        esac
        waitForInput && continue
        ;; ###################################################################

      advanced)
        while true; do # Advanced loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> ADVANCED"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Developer & Advanced features\n"\
						" ) Metadata       - create and optionally post metadata on-chain"\
						" ) Multi-Asset    - multi-asset nanagement"\
						" ) Delete Keys    - Delete all sign/cold keys from CNTools (wallet|pool|asset)"\
						"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Operation\n"
          select_opt "[m] Metadata" "[a] Multi-Asset" "[x] Delete Private Keys" "[h] Home"
          case $? in
            0) SUBCOMMAND="metadata" ;;
            1) SUBCOMMAND="multi-asset" ;;
            2) SUBCOMMAND="del-keys" ;;
            3) break ;;
          esac
          case $SUBCOMMAND in  
            metadata)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> ADVANCED >> METADATA"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available to pay for transaction fee!${NC}" && waitForInput && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitForInput && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "Select the type of metadata to post on-chain"
              println DEBUG "ref: https://github.com/input-output-hk/cardano-node-wiki/wiki/tx-metadata"
              select_opt "[n] No JSON Schema (default)" "[d] Detailed JSON Schema" "[c] Raw CBOR"
              case $? in
                0) metatype="no-schema" ;;
                1) metatype="detailed-schema" ;;
                2) metatype="cbor" ;;
              esac
              if [[ ${metatype} = "cbor" ]]; then
                fileDialog "Enter path to raw CBOR metadata file" && echo
                metafile="${file}"
              else
                metafile="${TMP_DIR}/metadata_$(date '+%Y%m%d%H%M%S').json"
                println DEBUG "\nDo you want to select a metadata file, enter URL to metadata file, or enter/paste metadata content?"
                select_opt "[f] File" "[u] URL" "[e] Enter"
                case $? in
                  0) fileDialog "Enter path to JSON metadata file" && echo
                    metafile="${file}"
                    if [[ ! -f "${metafile}" ]] || ! jq -er . "${metafile}" &>/dev/null; then
                      println ERROR "${FG_RED}ERROR${NC}: invalid JSON format or file not found"
                      waitForInput && continue
                    fi
                    println DEBUG "$(cat "${metafile}")\n"
                    ;;
                  1) tput sc && echo
                    getAnswerAnyCust meta_json_url "Enter URL to JSON metadata file"
                    if [[ ! "${meta_json_url}" =~ https?://.* ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: invalid URL format"
                      waitForInput && continue
                    fi
                    if ! curl -sL -m ${CURL_TIMEOUT} -o "${metafile}" ${meta_json_url} || ! jq -er . "${metafile}" &>/dev/null; then
                      println ERROR "${FG_RED}ERROR${NC}: metadata download failed, please make sure the URL point to a valid JSON file!"
                      waitForInput && continue
                    fi
                    tput rc && tput ed
                    println "Metadata file successfully downloaded to: ${FG_LGRAY}${metafile}${NC}"
                    ;;
                  2) println "Add an example metadata JSON scaffold?"
                    select_opt "[y] Yes" "[n] No"
                    case $? in
                      0) jq . <<< '{"1815":{"name":"Ada Lovelace","age":36,"parents":[{"id":0,"name":"George Gordon Byron"},{"id":1,"name":"Anne Isabella Byron"}]}}' > "${metafile}" ;;
                      1) : ;; # do nothing
                    esac
                    tput sc
                    DEFAULTEDITOR="$(command -v nano &>/dev/null && echo 'nano' || echo 'vi')"
                    println OFF "\nPaste or enter the metadata text, opening text editor ${FG_LGRAY}${DEFAULTEDITOR}${NC}"
                    println OFF "${FG_YELLOW}Please don't change default file path when saving${NC}"
                    exec >&6 2>&7 # normal stdout/stderr
                    waitForInput "press any key to open ${DEFAULTEDITOR}"
                    ${DEFAULTEDITOR} "${metafile}"
                    exec >&8 2>&9 # custom stdout/stderr
                    if [[ ! -f "${metafile}" ]] || ! jq -er . "${metafile}" &>/dev/null; then
                      println ERROR "${FG_RED}ERROR${NC}: file not found or invalid JSON format"
                      println ERROR "File: ${FG_LGRAY}${metafile}${NC}"
                      waitForInput && continue
                    fi
                    tput rc && tput ed
                    println "Metadata file successfully saved to: ${FG_LGRAY}${metafile}${NC}"
                    ;;
                esac
              fi
              println DEBUG "\nContinue to post metadata on-chain or stop at this point?"
              select_opt "[c] Continue" "[s] Stop"
              case $? in
                0) : ;; # do nothing
                1) continue ;;
              esac
              println DEBUG "\n# Select wallet to pay for metadata transaction fee"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "balance" "${WALLET_PAY_SK_FILENAME}"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for metadata transaction fee!" && waitForInput && continue ;;
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
                esac
              else
                selectWallet "balance"
                case $? in
                  1) waitForInput; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for metadata transaction fee!" && waitForInput && continue ;;
                esac
              fi
              echo
              getBaseAddress ${wallet_name}
              getPayAddress ${wallet_name}
              getBalance ${base_addr}
              base_lovelace=${assets[lovelace]}
              getBalance ${pay_addr}
              pay_lovelace=${assets[lovelace]}
              if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                # Both payment and base address available with funds, let user choose what to use
                println DEBUG "Select source wallet address"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
                echo
                select_opt "[b] Base (default)" "[e] Enterprise" "[Esc] Cancel"
                case $? in
                  0) addr="${base_addr}" ;;
                  1) addr="${pay_addr}" ;;
                  2) continue ;;
                esac
              elif [[ ${pay_lovelace} -gt 0 ]]; then
                addr="${pay_addr}"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
              elif [[ ${base_lovelace} -gt 0 ]]; then
                addr="${base_addr}"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                waitForInput && continue
              fi
              if ! sendMetadata; then
                waitForInput && continue
              fi
              echo
              if ! verifyTx ${addr}; then waitForInput && continue; fi
              echo
              println "Metadata successfully posted on-chain"
              waitForInput && continue
              ;; ###################################################################
            multi-asset)
              while true; do # Multi-Asset loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> ADVANCED >> MULTI-ASSET"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Multi-Asset Token Management\n"\
									" ) Create Policy  - create a new asset policy"\
									" ) List Assets    - list created/minted policies/assets (local)"\
									" ) Show Asset     - show minted asset information"\
									" ) Decrypt Policy - remove write protection and decrypt policy"\
									" ) Encrypt Policy - encrypt policy sign key and make all files immutable"\
									" ) Mint Asset     - mint new assets for selected policy"\
									" ) Burn Asset     - burn a given amount of assets in selected wallet"\
									" ) Register Asset - create/update JSON submission file for Cardano Token Registry"\
									"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select Multi-Asset Operation\n"
                select_opt "[c] Create Policy" "[l] List Assets" "[s] Show Asset" "[d] Decrypt / Unlock Policy" "[e] Encrypt / Lock Policy" "[m] Mint Asset" "[x] Burn Asset" "[r] Register Asset" "[b] Back" "[h] Home"
                case $? in
                  0) SUBCOMMAND="create-policy" ;;
                  1) SUBCOMMAND="list-assets" ;;
                  2) SUBCOMMAND="show-asset" ;;
                  3) SUBCOMMAND="decrypt-policy" ;;
                  4) SUBCOMMAND="encrypt-policy" ;;
                  5) SUBCOMMAND="mint-asset" ;;
                  6) SUBCOMMAND="burn-asset" ;;
                  7) SUBCOMMAND="register-asset" ;;
                  8) break ;;
                  9) break 2 ;;
                esac
                case $SUBCOMMAND in
                  create-policy)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> MULTI-ASSET >> CREATE POLICY"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    getAnswerAnyCust policy_name "Internal name to give the generated policy"
                    # Remove unwanted characters from policy name
                    policy_name=${policy_name//[^[:alnum:]]/_}
                    if [[ -z "${policy_name}" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: Empty policy name, please retry!"
                      waitForInput && continue
                    fi
                    policy_folder="${ASSET_FOLDER}/${policy_name}"
                    echo
                    if ! mkdir -p "${policy_folder}"; then
                      println ERROR "${FG_RED}ERROR${NC}: Failed to create directory for policy:\n${policy_folder}"
                      waitForInput && continue
                    fi
                    # Policy filenames
                    policy_sk_file="${policy_folder}/${ASSET_POLICY_SK_FILENAME}"
                    policy_vk_file="${policy_folder}/${ASSET_POLICY_VK_FILENAME}"
                    policy_script_file="${policy_folder}/${ASSET_POLICY_SCRIPT_FILENAME}"
                    policy_id_file="${policy_folder}/${ASSET_POLICY_ID_FILENAME}"
                    if [[ $(find "${policy_folder}" -type f -print0 | wc -c) -gt 0 ]]; then
                      println "${FG_RED}WARN${NC}: A policy ${FG_GREEN}${policy_name}${NC} already exist!"
                      println "      Choose another name or delete the existing one"
                      waitForInput && continue
                    fi
                    println ACTION "${CCLI} address key-gen --verification-key-file ${policy_vk_file} --signing-key-file ${policy_sk_file}"
                    if ! ${CCLI} address key-gen --verification-key-file "${policy_vk_file}" --signing-key-file "${policy_sk_file}"; then
                      println ERROR "${FG_RED}ERROR${NC}: failure during policy key creation!"; safeDel "${policy_folder}"; waitForInput && continue
                    fi
                    println ACTION "${CCLI} address key-hash --payment-verification-key-file ${policy_vk_file}"
                    if ! policy_key_hash=$(${CCLI} address key-hash --payment-verification-key-file "${policy_vk_file}"); then
                      println ERROR "${FG_RED}ERROR${NC}: failure during policy verification key hashing!"; safeDel "${policy_folder}"; waitForInput && continue
                    fi
                    println DEBUG "How long do you want the policy to be valid? (0/blank=unlimited)"
                    println DEBUG "${FG_YELLOW}Setting a limit will prevent you from minting/burning assets after the policy expire !!\nLeave blank/unlimited if unsure and just press enter${NC}"
                    getAnswerAnyCust ttl_enter "TTL (in seconds)"
                    ttl_enter=${ttl_enter:-0}
                    if ! isNumber ${ttl_enter}; then
                      println ERROR "\n${FG_RED}ERROR${NC}: invalid TTL number, non digit characters found: ${ttl_enter}"
                      safeDel "${policy_folder}"; waitForInput && continue
                    fi
                    if [[ ${ttl_enter} -eq 0 ]]; then
                      echo "{ \"keyHash\": \"${policy_key_hash}\", \"type\": \"sig\" }" > "${policy_script_file}"
                    else
                      ttl=$(( $(getSlotTipRef) + (ttl_enter/SLOT_LENGTH) ))
                      echo "{ \"type\": \"all\", \"scripts\": [ { \"slot\": ${ttl}, \"type\": \"before\" }, { \"keyHash\": \"${policy_key_hash}\", \"type\": \"sig\" } ] }" > "${policy_script_file}"
                    fi
                    println ACTION "${CCLI} transaction policyid --script-file ${policy_script_file}"
                    if ! policy_id=$(${CCLI} transaction policyid --script-file "${policy_script_file}"); then
                      println ERROR "${FG_RED}ERROR${NC}: failure during policy ID generation!"; safeDel "${policy_folder}"; waitForInput && continue
                    fi
                    echo "${policy_id}" > "${policy_id_file}"
                    chmod 600 "${policy_folder}/"*
                    echo
                    println "Policy Name   : ${FG_GREEN}${policy_name}${NC}"
                    println "Policy ID     : ${FG_LGRAY}${policy_id}${NC}"
                    println "Policy Expire : $([[ ${ttl_enter} -eq 0 ]] && echo "${FG_LGRAY}unlimited${NC}" || echo "${FG_LGRAY}$(getDateFromSlot ${ttl} '%(%F %T %Z)T')${NC}, ${FG_LGRAY}$(timeLeft $((ttl-$(getSlotTipRef))))${NC} remaining")"
                    println DEBUG "\nYou can now start minting your custom assets using this Policy!"
                    waitForInput && continue
                    ;; ###################################################################
                  list-assets)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> MULTI-ASSET >> LIST ASSETS"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No policies or assets found!${NC}" && waitForInput && continue
                    while IFS= read -r -d '' policy; do
                      echo
                      println "Policy Name   : ${FG_GREEN}$(basename "${policy}")${NC}"
                      println "Policy ID     : ${FG_LGRAY}$(cat "${policy}/${ASSET_POLICY_ID_FILENAME}")${NC}"
                      ttl=$(jq -er '.scripts[0].slot //0' "${policy}/${ASSET_POLICY_SCRIPT_FILENAME}")
                      current_slot=$(getSlotTipRef)
                      if [[ ${ttl} -eq 0 ]]; then
                        println "Policy Expire : ${FG_LGRAY}unlimited${NC}"
                      elif [[ ${ttl} -gt ${current_slot} ]]; then
                        println "Policy Expire : ${FG_LGRAY}$(getDateFromSlot ${ttl} '%(%F %T %Z)T')${NC}, ${FG_LGRAY}$(timeLeft $((ttl-current_slot)))${NC} remaining"
                      else
                        println "Policy Expire : ${FG_LGRAY}$(getDateFromSlot ${ttl} '%(%F %T %Z)T')${NC}, ${FG_RED}expired $(timeLeft $((current_slot-ttl))) ago !!${NC}"
                      fi
                      if [[ $(find "${policy}" -mindepth 1 -maxdepth 1 -type f -name '*.asset' -print0 | wc -c) -gt 0 ]]; then
                        while IFS= read -r -d '' asset; do
                          asset_name=$(jq -r '.name //empty' "${asset}")
                          [[ -z ${asset_name} ]] && asset_name_hex="" || asset_name_hex="$(asciiToHex "${asset_name}")"
                          println "Asset         : Name: ${FG_MAGENTA}${asset_name}${NC} (${FG_LGRAY}${asset_name_hex}${NC}) - Minted: ${FG_LBLUE}$(formatAsset "$(jq -r .minted "${asset}")")${NC}"
                        done < <(find "${policy}" -mindepth 1 -maxdepth 1 -type f -name '*.asset' -print0 | sort -z)
                      else
                        println "Asset         : ${FG_LGRAY}No assets minted for this policy!${NC}"
                      fi
                    done < <(find "${ASSET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
                    waitForInput && continue
                    ;; ###################################################################
                  show-asset)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> MULTI-ASSET >> SHOW ASSET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No policies or assets found!${NC}" && waitForInput && continue
                    println DEBUG "# Select minted asset to show information for"
                    selectAsset
                    case $? in
                      1) waitForInput; continue ;;
                      2) continue ;;
                    esac
                    echo
                    policy_id=$(cat "${ASSET_FOLDER}/${policy_dir}/${ASSET_POLICY_ID_FILENAME}")
                    println "Policy Name    : ${FG_GREEN}${policy_dir}${NC}"
                    println "Policy ID      : ${FG_LGRAY}${policy_id}${NC}"
                    ttl=$(jq -er '.scripts[0].slot //0' "${ASSET_FOLDER}/${policy_dir}/${ASSET_POLICY_SCRIPT_FILENAME}")
                    current_slot=$(getSlotTipRef)
                    if [[ ${ttl} -eq 0 ]]; then
                      println "Policy Expire  : ${FG_LGRAY}unlimited${NC}"
                    elif [[ ${ttl} -gt ${current_slot} ]]; then
                      println "Policy Expire  : ${FG_LGRAY}$(getDateFromSlot ${ttl} '%(%F %T %Z)T')${NC}, ${FG_LGRAY}$(timeLeft $((ttl-current_slot)))${NC} remaining"
                    else
                      println "Policy Expire  : ${FG_LGRAY}$(getDateFromSlot ${ttl} '%(%F %T %Z)T')${NC}, ${FG_RED}expired $(timeLeft $((current_slot-ttl))) ago !!${NC}"
                    fi
                    asset_name=$(jq -r '.name //empty' "${asset_file}")
                    [[ -z ${asset_name} ]] && asset_name_hex="" || asset_name_hex="$(asciiToHex "${asset_name}")"
                    println "Asset Name     : ${FG_MAGENTA}${asset_name}${NC}${FG_LGRAY} (${asset_name_hex})${NC}"
                    getAssetInfo "${policy_id}" "${asset_name_hex}"
                    case $? in
                      0) println "Fingerprint    : ${FG_LGRAY}${a_fingerprint}${NC}"
                         println "In Circulation : ${FG_LBLUE}$(formatAsset ${a_total_supply})${NC}"
                         println "Mint Count     : ${FG_LBLUE}${a_mint_cnt}${NC}"
                         println "Burn Count     : ${FG_LBLUE}${a_burn_cnt}${NC}"
                         println "Mint Tx Meta   :"
                         if [[ ${a_minting_tx_metadata} != '-' ]]; then jq -r . <<< "${a_minting_tx_metadata}"; fi
                         println "Token Reg Meta :"
                         if [[ ${a_token_registry_metadata} != '-' ]]; then jq -r . <<< "${a_token_registry_metadata}"; fi ;;
                      1) println "ERROR" "${FG_RED}KOIOS_API ERROR${NC}: ${error_msg}" ;;
                      2) a_minted=$(jq -er '.minted //0' "${asset_file}")
                         println "In Circulation : ${FG_LBLUE}$(formatAsset "$(jq -er '.minted //0' "${asset_file}")")${NC} (local tracking)" ;;
                    esac
                    a_last_update=$(jq -er '.lastUpdate //"-"' "${asset_file}")
                    a_last_action=$(jq -er '.lastAction //"-"' "${asset_file}")
                    println "Last Updated   : ${FG_LGRAY}${a_last_update}${NC}"
                    println "Last Action    : ${FG_LGRAY}${a_last_action}${NC}"
                    waitForInput && continue
                    ;; ###################################################################
                  decrypt-policy)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> MULTI-ASSET >> DECRYPT / UNLOCK POLICY"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No policies available!${NC}" && waitForInput && continue
                    println DEBUG "# Select policy to decrypt"
                    selectPolicy "encrypted"
                    case $? in
                      1) waitForInput; continue ;;
                      2) continue ;;
                    esac
                    filesUnlocked=0
                    keysDecrypted=0
                    echo
                    println DEBUG "# Removing write protection from all policy files"
                    while IFS= read -r -d '' file; do
                      if [[ ${ENABLE_CHATTR} = true && $(lsattr -R "$file") =~ -i- ]]; then
                        sudo chattr -i "${file}"
                      fi
                      chmod 600 "${file}"
                      filesUnlocked=$((++filesUnlocked))
                      println DEBUG "${file}"
                    done < <(find "${ASSET_FOLDER}/${policy_name}" -mindepth 1 -maxdepth 1 -type f -print0)
                    if [[ $(find "${ASSET_FOLDER}/${policy_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -gt 0 ]]; then
                      echo
                      println "# Decrypting GPG encrypted policy key"
                      if ! getPasswordCust; then # $password variable populated by getPasswordCust function
                        println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                        waitForInput && continue
                      fi
                      while IFS= read -r -d '' file; do
                        decryptFile "${file}" "${password}" && \
                        chmod 600 "${file::-4}" && \
                        keysDecrypted=$((++keysDecrypted))
                      done < <(find "${ASSET_FOLDER}/${policy_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
                      unset password
                    fi
                    echo
                    println "Policy decrypted : ${FG_GREEN}${policy_name}${NC}"
                    println "Files unlocked   : ${FG_LBLUE}${filesUnlocked}${NC}"
                    println "Files decrypted  : ${FG_LBLUE}${keysDecrypted}${NC}"
                    if [[ ${filesUnlocked} -ne 0 || ${keysDecrypted} -ne 0 ]]; then
                      echo
                      println DEBUG "${FG_YELLOW}Policy files are now unprotected${NC}"
                      println DEBUG "Use 'ADVANCED >> MULTI-ASSET >> ENCRYPT / LOCK POLICY' to re-lock"
                    fi
                    waitForInput && continue
                    ;; ###################################################################
                  encrypt-policy)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> MULTI-ASSET >> ENCRYPT / LOCK POLICY"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No policies available!${NC}" && waitForInput && continue
                    println DEBUG "# Select policy to encrypt"
                    selectPolicy "encrypted"
                    case $? in
                      1) waitForInput; continue ;;
                      2) continue ;;
                    esac
                    filesLocked=0
                    keysEncrypted=0
                    if [[ $(find "${ASSET_FOLDER}/${policy_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -le 0 ]]; then
                      echo
                      println DEBUG "# Encrypting policy signing key with GPG"
                      if ! getPasswordCust confirm; then # $password variable populated by getPasswordCust function
                        println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                        waitForInput && continue
                      fi
                      keyFiles=(
                        "${ASSET_FOLDER}/${policy_name}/${ASSET_POLICY_SK_FILENAME}"
                      )
                      for keyFile in "${keyFiles[@]}"; do
                        if [[ -f "${keyFile}" ]]; then
                          chmod 400 "${keyFile}" && \
                          encryptFile "${keyFile}" "${password}" && \
                          keysEncrypted=$((++keysEncrypted))
                        fi
                      done
                      unset password
                    else
                      echo
                      println DEBUG "${FG_YELLOW}NOTE${NC}: found GPG encrypted files in folder, please decrypt/unlock policy files before encrypting"
                      waitForInput && continue
                    fi
                    echo
                    println DEBUG "# Write protecting all policy files with 400 permission and if enabled 'chattr +i'"
                    while IFS= read -r -d '' file; do
                      chmod 400 "$file"
                      if [[ ${ENABLE_CHATTR} = true && ! $(lsattr -R "$file") =~ -i- ]]; then
                        sudo chattr +i "$file"
                      fi
                      filesLocked=$((++filesLocked))
                      println DEBUG "$file"
                    done < <(find "${ASSET_FOLDER}/${policy_name}" -mindepth 1 -maxdepth 1 -type f -print0)
                    echo
                    println "Policy encrypted : ${FG_GREEN}${policy_name}${NC}"
                    println "Files locked     : ${FG_LBLUE}${filesLocked}${NC}"
                    println "Files encrypted  : ${FG_LBLUE}${keysEncrypted}${NC}"
                    if [[ ${filesLocked} -ne 0 || ${keysEncrypted} -ne 0 ]]; then
                      echo
                      println DEBUG "${FG_BLUE}INFO${NC}: policy files are now protected"
                      println DEBUG "Use 'ADVANCED >> MULTI-ASSET >> DECRYPT / UNLOCK POLICY' to unlock"
                    fi
                    waitForInput && continue
                    ;; ###################################################################
                  mint-asset)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> MULTI-ASSET >> MINT ASSET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitForInput && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    echo
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No policies found!${NC}\n\nPlease first create a policy to mint asset with" && waitForInput && continue
                    println DEBUG "# Select the policy to use when minting the asset"
                    selectPolicy "all" "${ASSET_POLICY_SK_FILENAME}" "${ASSET_POLICY_VK_FILENAME}" "${ASSET_POLICY_SCRIPT_FILENAME}" "${ASSET_POLICY_ID_FILENAME}"
                    case $? in
                      1) waitForInput; continue ;;
                      2) continue ;;
                    esac
                    policy_folder="${ASSET_FOLDER}/${policy_name}"
                    # Policy filenames
                    policy_sk_file="${policy_folder}/${ASSET_POLICY_SK_FILENAME}"
                    policy_vk_file="${policy_folder}/${ASSET_POLICY_VK_FILENAME}"
                    policy_script_file="${policy_folder}/${ASSET_POLICY_SCRIPT_FILENAME}"
                    policy_id_file="${policy_folder}/${ASSET_POLICY_ID_FILENAME}"
                    policy_id="$(cat "${policy_id_file}")"
                    policy_ttl=$(jq -r '.scripts[0].slot //0' "${policy_script_file}")
                    [[ ${policy_ttl} -gt 0 && ${policy_ttl} -lt $(getSlotTipRef) ]] && println ERROR "${FG_RED}ERROR${NC}: Policy expired!" && waitForInput && continue
                    echo
                    if [[ $(find "${policy_folder}" -type f -name '*.asset' -print0 | wc -c) -gt 0 ]]; then
                      println DEBUG "# Assets minted for this Policy\n"
                      asset_name_maxlen=5; asset_amount_maxlen=12
                      while IFS= read -r -d '' asset; do
                        asset_name=$(jq -r '.name //empty' "${asset}")
                        [[ ${#asset_name} -gt ${asset_name_maxlen} ]] && asset_name_maxlen=${#asset_name}
                        asset_minted=$(jq -r '.minted //0' "${asset}")
                        [[ ${#asset_minted} -gt ${asset_amount_maxlen} ]] && asset_amount_maxlen=${#asset_minted}
                      done < <(find "${policy_folder}" -mindepth 1 -maxdepth 1 -type f -name '*.asset' -print0 | sort -z)
                      println DEBUG "$(printf "%${asset_amount_maxlen}s | %s\n" "Total Amount" "Policy ID[.AssetName]")"
                      println DEBUG "$(printf "%$((asset_amount_maxlen+1))s+%$((asset_name_maxlen+58))s\n" "" "" | tr " " "-")"
                      while IFS= read -r -d '' asset; do
                        asset_name=$(jq -r '.name //empty' "${asset}")
                        [[ -z ${asset_name} ]] && asset_name="${FG_LGRAY}${policy_id}${NC}" || asset_name="${FG_LGRAY}${policy_id}.${FG_MAGENTA}${asset_name}${NC}"
                        asset_minted=$(jq -r '.minted //0' "${asset}")
                        println DEBUG "$(printf "${FG_LBLUE}%${asset_amount_maxlen}s${NC} | %s\n" "${asset_minted}" "${asset_name}")"
                      done < <(find "${policy_folder}" -mindepth 1 -maxdepth 1 -type f -name '*.asset' -print0 | sort -z)
                      println DEBUG "\nEnter an existing AssetName to mint more tokens or enter a new name to create a new Asset for this Policy"
                    fi
                    getAnswerAnyCust asset_name "Asset Name (empty valid)"
                    [[ ${asset_name} =~ ^[^[:alnum:]]$ ]] && println ERROR "${FG_RED}ERROR${NC}: Asset name should only contain alphanummeric chars!" && waitForInput && continue
                    [[ ${#asset_name} -gt 32 ]] && println ERROR "${FG_RED}ERROR${NC}: Asset name is limited to 32 chars in length!" && waitForInput && continue
                    asset_file="${policy_folder}/${asset_name// /_}.asset"
                    echo
                    getAnswerAnyCust assets_to_mint "Amount (commas allowed as thousand separator)"
                    assets_to_mint="${assets_to_mint//,}"
                    [[ -z "${assets_to_mint}" ]] && println ERROR "${FG_RED}ERROR${NC}: Amount empty, please set a valid integer number!" && waitForInput && continue
                    if ! isNumber ${assets_to_mint}; then println ERROR "${FG_RED}ERROR${NC}: Invalid number, should be an integer number. Decimals not allowed!" && waitForInput && continue; fi
                    [[ -f "${asset_file}" ]] && asset_minted=$(( $(jq -r .minted "${asset_file}") + assets_to_mint )) || asset_minted=${assets_to_mint}
                    metafile_param=""
                    println DEBUG "\nDo you want to attach a metadata JSON file to the minting transaction?"
                    select_opt "[n] No" "[y] Yes"
                    case $? in
                      0) : ;; # do nothing
                      1) fileDialog "Enter path to metadata JSON file" "${TMP_DIR}/" && echo
                        metafile=${file}
                        [[ -z "${metafile}" ]] && println ERROR "${FG_RED}ERROR${NC}: Metadata file path empty!" && waitForInput && continue
                        [[ ! -f "${metafile}" ]] && println ERROR "${FG_RED}ERROR${NC}: File not found: ${metafile}" && waitForInput && continue
                        if ! jq -er . "${metafile}"; then println ERROR "${FG_RED}ERROR${NC}: Metadata file not a valid json file!" && waitForInput && continue; fi
                        metafile_param="--metadata-json-file ${metafile}"
                        ;;
                    esac
                    println DEBUG "\n# Select wallet to mint assets on (also used for transaction fee)"
                    if [[ ${op_mode} = "online" ]]; then
                      selectWallet "balance" "${WALLET_PAY_SK_FILENAME}"
                      case $? in
                        1) waitForInput; continue ;;
                        2) continue ;;
                      esac
                      getWalletType ${wallet_name}
                      case $? in
                        2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                        3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
                      esac
                    else
                      selectWallet "balance"
                      case $? in
                        1) waitForInput; continue ;;
                        2) continue ;;
                      esac
                    fi
                    echo
                    getBaseAddress ${wallet_name}
                    getPayAddress ${wallet_name}
                    getBalance ${base_addr}
                    base_lovelace=${assets[lovelace]}
                    getBalance ${pay_addr}
                    pay_lovelace=${assets[lovelace]}
                    if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                      # Both payment and base address available with funds, let user choose what to use
                      println DEBUG "Select source wallet address"
                      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                        println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
                        println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
                      fi
                      echo
                      select_opt "[b] Base (default)" "[e] Enterprise" "[Esc] Cancel"
                      case $? in
                        0) addr="${base_addr}" ;;
                        1) addr="${pay_addr}" ;;
                        2) continue ;;
                      esac
                      echo
                    elif [[ ${pay_lovelace} -gt 0 ]]; then
                      addr="${pay_addr}"
                      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                        println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} Ada\n" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
                      fi
                    elif [[ ${base_lovelace} -gt 0 ]]; then
                      addr="${base_addr}"
                      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                        println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} Ada\n" "Funds :"  "$(formatLovelace ${base_lovelace})")"
                      fi
                    else
                      println ERROR "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                      waitForInput && continue
                    fi
                    if ! mintAsset; then
                      waitForInput && continue
                    fi
                    if [[ ! -f "${asset_file}" ]]; then echo "{}" > "${asset_file}"; fi
                    assetJSON=$( jq ". += {minted: \"${asset_minted}\", name: \"${asset_name}\", policyID: \"${policy_id}\", assetName: \"$(asciiToHex "${asset_name}")\", policyValidBeforeSlot: \"${policy_ttl}\", lastUpdate: \"$(date -R)\", lastAction: \"Minted $(formatAsset ${assets_to_mint})\"}" < "${asset_file}")
                    echo -e "${assetJSON}" > "${asset_file}"
                    echo
                    if ! verifyTx ${addr}; then waitForInput && continue; fi
                    echo
                    println "Assets successfully minted!"
                    println "Policy Name    : ${FG_GREEN}${policy_name}${NC}"
                    println "Policy ID      : ${FG_LGRAY}${policy_id}${NC}"
                    [[ -z ${asset_name} ]] && asset_name_hex="" || asset_name_hex="$(asciiToHex "${asset_name}")"
                    println "Asset Name     : ${FG_MAGENTA}${asset_name}${NC}${FG_LGRAY} (${asset_name_hex})${NC}"
                    getAssetInfo "${policy_id}" "${asset_name_hex}"
                    case $? in
                      0) println "Fingerprint    : ${FG_LGRAY}${a_fingerprint}${NC}"
                         println "Minted         : ${FG_LBLUE}$(formatAsset ${assets_to_mint})${NC}"
                         println "In Circulation : ${FG_LBLUE}$(formatAsset ${a_total_supply})${NC}"
                         println "Mint Count     : ${FG_LBLUE}${a_mint_cnt}${NC}"
                         println "Burn Count     : ${FG_LBLUE}${a_burn_cnt}${NC}" ;;
                      1) println "ERROR" "${FG_RED}KOIOS_API ERROR${NC}: ${error_msg}" ;;
                      2) println "Minted         : ${FG_LBLUE}$(formatAsset ${assets_to_mint})${NC}"
                         println "In Circulation : ${FG_LBLUE}$(formatAsset ${asset_minted})${NC} (local tracking)" ;;
                    esac
                    println DEBUG "\n${FG_YELLOW}Please note that it can take a couple of minutes before minted asset show in wallet${NC}"
                    waitForInput && continue
                    ;; ###################################################################
                  burn-asset)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> MULTI-ASSET >> BURN ASSET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitForInput && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    echo
                    println DEBUG "# Select wallet with assets to burn"
                    if [[ ${op_mode} = "online" ]]; then
                      selectWallet "balance" "${WALLET_PAY_SK_FILENAME}"
                      case $? in
                        1) waitForInput; continue ;;
                        2) continue ;;
                      esac
                      getWalletType ${wallet_name}
                      case $? in
                        0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet for asset burning!" && waitForInput && continue ;;
                        2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
                        3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
                      esac
                    else
                      selectWallet "balance"
                      case $? in
                        1) waitForInput; continue ;;
                        2) continue ;;
                      esac
                      getWalletType ${wallet_name}
                      case $? in
                        0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet for asset burning!" && waitForInput && continue ;;
                      esac
                    fi
                    # Let user choose asset on wallet to burn, both base and enterprise, fee payed with same address
                    assets_on_wallet=()
                    getBaseAddress ${wallet_name}
                    getBalance ${base_addr}
                    declare -gA base_assets=(); for idx in "${!assets[@]}"; do base_assets[${idx}]=${assets[${idx}]}; done
                    for asset in "${!base_assets[@]}"; do
                      [[ ${asset} = "lovelace" ]] && continue
                      IFS='.' read -ra asset_arr <<< "${asset}"
                      [[ -z ${asset_arr[1]} ]] && asset_ascii_name="" || asset_ascii_name=$(hexToAscii ${asset_arr[1]})
                      assets_on_wallet+=( "${asset} (${asset_ascii_name}) [base addr]" )
                    done
                    getPayAddress ${wallet_name}
                    getBalance ${pay_addr}
                    declare -gA pay_assets=(); for idx in "${!assets[@]}"; do pay_assets[${idx}]=${assets[${idx}]}; done
                    for asset in "${!pay_assets[@]}"; do
                      [[ ${asset} = "lovelace" ]] && continue
                      IFS='.' read -ra asset_arr <<< "${asset}"
                      [[ -z ${asset_arr[1]} ]] && asset_ascii_name="" || asset_ascii_name=$(hexToAscii ${asset_arr[1]})
                      assets_on_wallet+=( "${asset} (${asset_ascii_name}) [enterprise addr]" )
                    done
                    echo
                    [[ ${#assets_on_wallet[@]} -eq 0 ]] && println ERROR "${FG_RED}ERROR${NC}: Wallet doesn't contain any assets!" && waitForInput && continue
                    println DEBUG "# Select Asset to burn"
                    select_opt "${assets_on_wallet[@]}" "[Esc] Cancel"
                    selection=$?
                    [[ ${selected_value} = "[Esc] Cancel" ]] && continue
                    IFS=' ' read -ra selection_arr <<< "${assets_on_wallet[${selection}]}"
                    asset="${selection_arr[0]}"
                    IFS='.' read -ra asset_arr <<< "${selection_arr[0]}"
                    selection_arr_length=${#selection_arr[@]}
                    if [[ ${selection_arr[*]:$((selection_arr_length-2))} = "[base addr]" ]]; then 
                      addr=${base_addr}
                      wallet_source="base"
                      curr_asset_amount=${base_assets[${asset}]}
                    else
                      addr=${pay_addr}
                      wallet_source="enterprise"
                      curr_asset_amount=${pay_assets[${asset}]}
                    fi
                    echo
                    
                    # Search policies for a match
                    asset_file=""
                    while IFS= read -r -d '' file; do
                      [[ ${asset_arr[0]} = "$(jq -r .policyID ${file})" ]] && asset_file="${file}" && break
                    done < <(find "${ASSET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name '*.asset' -print0)
                    [[ -z "${asset_file}" ]] && println ERROR "${FG_RED}ERROR${NC}: Searched all available policies in '${ASSET_FOLDER}' for matching '.asset' file but non found!" && waitForInput && continue
                    
                    [[ ${#asset_arr[@]} -eq 1 ]] && asset_name="" || asset_name="${asset_arr[1]}"
                    
                    # Policy filenames
                    policy_folder="$(dirname "${asset_file}")"
                    policy_name="$(basename "${policy_folder}")"
                    policy_sk_file="${policy_folder}/${ASSET_POLICY_SK_FILENAME}"
                    policy_vk_file="${policy_folder}/${ASSET_POLICY_VK_FILENAME}"
                    policy_script_file="${policy_folder}/${ASSET_POLICY_SCRIPT_FILENAME}"
                    policy_id_file="${policy_folder}/${ASSET_POLICY_ID_FILENAME}"
                    policy_id="$(cat "${policy_id_file}")"
                    policy_ttl=$(jq -r '.scripts[0].slot //0' "${policy_script_file}")
                    [[ ${policy_ttl} -gt 0 && ${policy_ttl} -lt $(getSlotTipRef) ]] && println ERROR "${FG_RED}ERROR${NC}: Policy expired!" && waitForInput && continue
                    # ask amount to burn
                    println DEBUG "Available assets to burn: ${FG_LBLUE}$(formatAsset "${curr_asset_amount}")${NC}\n"
                    getAnswerAnyCust assets_to_burn "Amount (commas allowed as thousand separator)"
                    assets_to_burn="${assets_to_burn//,}"
                    [[ ${assets_to_burn} = "all" ]] && assets_to_burn=${curr_asset_amount}
                    if ! isNumber ${assets_to_burn}; then println ERROR "${FG_RED}ERROR${NC}: Invalid number, should be an integer number. Decimals not allowed!" && waitForInput && continue; fi
                    [[ ${assets_to_burn} -gt ${curr_asset_amount} ]] && println ERROR "${FG_RED}ERROR${NC}: Amount exceeding assets in address, you can only burn ${FG_LBLUE}$(formatAsset "${asset_amount}")${NC}" && waitForInput && continue
                    asset_minted=$(( $(jq -r .minted "${asset_file}") - assets_to_burn ))
                    # Attach metadata?
                    metafile_param=""
                    println DEBUG "\nDo you want to attach a metadata JSON file to the burning transaction?"
                    select_opt "[n] No" "[y] Yes"
                    case $? in
                      0) : ;; # do nothing
                      1) fileDialog "Enter path to metadata JSON file" "${TMP_DIR}/" && echo
                        metafile=${file}
                        [[ -z "${metafile}" ]] && println ERROR "${FG_RED}ERROR${NC}: Metadata file path empty!" && waitForInput && continue
                        [[ ! -f "${metafile}" ]] && println ERROR "${FG_RED}ERROR${NC}: File not found: ${metafile}" && waitForInput && continue
                        if ! jq -er . "${metafile}"; then println ERROR "${FG_RED}ERROR${NC}: Metadata file not a valid json file!" && waitForInput && continue; fi
                        metafile_param="--metadata-json-file ${metafile}"
                        ;;
                    esac
                    echo
                    # Call burn helper function
                    if ! burnAsset; then
                      waitForInput && continue
                    fi
                    # TODO: Update asset file
                    if [[ ! -f "${asset_file}" ]]; then echo "{}" > "${asset_file}"; fi
                    assetJSON=$( jq ". += {minted: \"${asset_minted}\", name: \"$(hexToAscii "${asset_name}")\", policyID: \"${policy_id}\", policyValidBeforeSlot: \"${policy_ttl}\", lastUpdate: \"$(date -R)\", lastAction: \"Burned $(formatAsset ${assets_to_burn})\"}" < "${asset_file}")
                    echo -e "${assetJSON}" > "${asset_file}"
                    echo
                    if ! verifyTx ${addr}; then waitForInput && continue; fi
                    echo
                    println "Assets successfully burned!"
                    println "Policy Name     : ${FG_GREEN}${policy_name}${NC}"
                    println "Policy ID       : ${FG_LGRAY}${policy_id}${NC}"
                    [[ -z ${asset_name} ]] && asset_name_ascii="" || asset_name_ascii="$(hexToAscii "${asset_name}")"
                    println "Asset Name      : ${FG_MAGENTA}${asset_name_ascii}${NC}${FG_LGRAY} (${asset_name})${NC}"
                    println "Left in Address : ${FG_LBLUE}$(formatAsset $(( curr_asset_amount - assets_to_burn )))${NC}"
                    getAssetInfo "${policy_id}" "${asset_name}"
                    case $? in
                      0) println "Fingerprint     : ${FG_LGRAY}${a_fingerprint}${NC}"
                         println "Burned          : ${FG_LBLUE}$(formatAsset ${assets_to_burn})${NC}"
                         println "In Circulation  : ${FG_LBLUE}$(formatAsset ${a_total_supply})${NC}"
                         println "Mint Count      : ${FG_LBLUE}${a_mint_cnt}${NC}"
                         println "Burn Count      : ${FG_LBLUE}${a_burn_cnt}${NC}" ;;
                      1) println "ERROR" "${FG_RED}KOIOS_API ERROR${NC}: ${error_msg}" ;;
                      2) println "Burned          : ${FG_LBLUE}$(formatAsset ${assets_to_burn})${NC}"
                         println "In Circulation  : ${FG_LBLUE}$(formatAsset ${asset_minted})${NC} (local tracking)" ;;
                    esac
                    println DEBUG "\n${FG_YELLOW}Please note that burned assets can take a couple of minutes before being reflected in wallet${NC}"
                    waitForInput && continue
                    ;; ###################################################################
                  register-asset)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> MULTI-ASSET >> REGISTER ASSET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    if ! cmdAvailable "token-metadata-creator"; then
                      println ERROR "Please follow instructions on Guild Operators site to download or build the tool:"
                      println ERROR "${FG_YELLOW}https://cardano-community.github.io/guild-operators/Build/offchain-metadata-tools/${NC}"
                      waitForInput && continue
                    fi
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No policies found!${NC}\n\nPlease first create a policy to use for Cardano Token Registry" && waitForInput && continue
                    println DEBUG "# Select the policy to use for Cardano Token Registry"
                    selectPolicy "all" "${ASSET_POLICY_SK_FILENAME}" "${ASSET_POLICY_SCRIPT_FILENAME}" "${ASSET_POLICY_ID_FILENAME}"
                    case $? in
                      1) waitForInput; continue ;;
                      2) continue ;;
                    esac
                    policy_folder="${ASSET_FOLDER}/${policy_name}"
                    # Policy filenames
                    policy_sk_file="${policy_folder}/${ASSET_POLICY_SK_FILENAME}"
                    policy_script_file="${policy_folder}/${ASSET_POLICY_SCRIPT_FILENAME}"
                    policy_id="$(cat "${policy_folder}/${ASSET_POLICY_ID_FILENAME}")"
                    echo
                    if [[ $(find "${policy_folder}" -type f -name '*.asset' -print0 | wc -c) -gt 0 ]]; then
                      println DEBUG "# Assets previously minted for this Policy\n"
                      asset_name_maxlen=5; asset_amount_maxlen=12
                      while IFS= read -r -d '' asset; do
                        asset_filename=$(basename "${asset}")
                        [[ -z ${asset_filename%.*} ]] && asset_name="." || asset_name="${asset_filename%.*}"
                        [[ ${#asset_name} -gt ${asset_name_maxlen} ]] && asset_name_maxlen=${#asset_name}
                        asset_minted=$(jq -r '.minted //0' "${asset}")
                        [[ ${#asset_minted} -gt ${asset_amount_maxlen} ]] && asset_amount_maxlen=${#asset_minted}
                      done < <(find "${policy_folder}" -mindepth 1 -maxdepth 1 -type f -name '*.asset' -print0 | sort -z)
                      println DEBUG "$(printf "%${asset_amount_maxlen}s | %s\n" "Total Amount" "Policy ID[.AssetName]")"
                      println DEBUG "$(printf "%$((asset_amount_maxlen+1))s+%$((asset_name_maxlen+58))s\n" "" "" | tr " " "-")"
                      while IFS= read -r -d '' asset; do
                        asset_filename=$(basename "${asset}")
                        [[ -z ${asset_filename%.*} ]] && asset_name="${FG_LGRAY}${policy_id}${NC}" || asset_name="${FG_LGRAY}${policy_id}.${FG_MAGENTA}${asset_filename%.*}${NC}"
                        asset_minted=$(jq -r '.minted //0' "${asset}")
                        println DEBUG "$(printf "${FG_LBLUE}%${asset_amount_maxlen}s${NC} | %s\n" "${asset_minted}" "${asset_name}")"
                      done < <(find "${policy_folder}" -mindepth 1 -maxdepth 1 -type f -name '*.asset' -print0 | sort -z)
                      echo
                    fi
                    println "Please enter the asset name as part of PolicyID.AssetName to create registry file for, either a previously minted coin or new"
                    getAnswerAnyCust asset_name "Asset Name (empty valid)"
                    [[ ${asset_name} =~ ^[^[:alnum:]]$ ]] && println ERROR "${FG_RED}ERROR${NC}: Asset name should only contain alphanummeric chars!" && waitForInput && continue
                    [[ ${#asset_name} -gt 32 ]] && println ERROR "${FG_RED}ERROR${NC}: Asset name is limited to 32 chars in length!" && waitForInput && continue
                    asset_file="${policy_folder}/${asset_name}.asset"
                    echo
                    sequence_number=0
                    if [[ -f ${asset_file} ]]; then # a previous asset file exist, check if metadata has previously been entered
                      if jq -er .metadata "${asset_file}" &>/dev/null; then
                        println DEBUG "${FG_YELLOW}Previous metadata registration found:${NC}"
                        jq -r .metadata "${asset_file}"
                        sequence_number=$(( $(jq -r '.metadata.sequenceNumber //0' "${asset_file}" 2>/dev/null) + 1 ))
                        echo
                      fi
                    fi
                    println DEBUG "# Enter metadata (optional fields can be left empty)"
                    getAnswerAnyCust meta_name "Name        [${FG_RED}required${NC}] (Max. 50 chars) "
                    [[ -z ${meta_name} || ${#meta_name} -gt 50 ]] && println ERROR "\n${FG_RED}ERROR${NC}: Metadata name is a required field and limited to 50 chars in length!" && waitForInput && continue
                    getAnswerAnyCust meta_desc "Description [${FG_RED}required${NC}] (Max. 500 chars)"
                    [[ -z ${meta_desc} || ${#meta_desc} -gt 500 ]] && println ERROR "\n${FG_RED}ERROR${NC}: Metadata description is a required field and limited to 500 chars in length!" && waitForInput && continue
                    getAnswerAnyCust meta_ticker "Ticker      [${FG_YELLOW}optional${NC}] (3-9 chars)     "
                    [[ -n ${meta_ticker} && ( ${#meta_ticker} -lt 3 || ${#meta_ticker} -gt 9 ) ]] && println ERROR "\n${FG_RED}ERROR${NC}: Metadata ticker is limited to 3-9 chars in length!" && waitForInput && continue
                    getAnswerAnyCust meta_url "URL         [${FG_YELLOW}optional${NC}] (Max. 250 chars)"
                    [[ -n ${meta_url} && ( ! ${meta_url} =~ https://.* || ${#meta_url} -gt 250 ) ]] && println ERROR "\n${FG_RED}ERROR${NC}: Invalid metadata URL format or greater than 250 char limit!" && waitForInput && continue
                    getAnswerAnyCust meta_decimals "Decimals    [${FG_YELLOW}optional${NC}]"
                    [[ -n ${meta_decimals} ]] && ! isNumber ${meta_decimals} && println ERROR "\n${FG_RED}ERROR${NC}: Invalid decimal number" && waitForInput && continue
                    fileDialog "Logo/Icon   [${FG_YELLOW}optional${NC}] (PNG, <64kb)    " "${TMP_DIR}/"
                    meta_logo="${file}"
                    if [[ -n ${meta_logo} ]]; then
                      [[ ! -f ${meta_logo} ]] && println ERROR "\n${FG_RED}ERROR${NC}: Logo not found!" && waitForInput && continue
                      [[ $(wc -c ${meta_logo} | cut -d' ' -f1) -gt 64000 ]] && println ERROR "\n${FG_RED}ERROR${NC}: Logo more than 64kb in size!" && waitForInput && continue
                      [[ $(file -b ${meta_logo}) != "PNG"* ]] && println ERROR "\n${FG_RED}ERROR${NC}: Logo not of PNG image type!" && waitForInput && continue
                    fi
                    
                    asset_subject="${policy_id}$(asciiToHex "${asset_name}")"
                    
                    cmd_args=(
                      "entry"
                      "${asset_subject}"
                      "--init"
                      "--name" "${meta_name}"
                      "--description" "${meta_desc}"
                      "--policy" "${policy_script_file}"
                    )
                    [[ -n ${meta_ticker} ]] && cmd_args+=( "--ticker" "${meta_ticker}" )
                    [[ -n ${meta_url} ]] && cmd_args+=( "--url" "${meta_url}" )
                    [[ -n ${meta_decimals} && ${meta_decimals} -gt 0 ]] && cmd_args+=( "--decimals" "${meta_decimals}" )
                    [[ -n ${meta_logo} ]] && cmd_args+=( "--logo" "${meta_logo}" )
                    
                    pushd ${policy_folder} &>/dev/null || { println ERROR "\n${FG_RED}ERROR${NC}: unable to change directory to: ${policy_folder}" && waitForInput && continue; }
                    
                    # Create JSON draft
                    println DEBUG false "\nCreating Cardano Metadata Registry JSON draft file ..."
                    ! meta_file=$(token-metadata-creator "${cmd_args[@]}" 2>&1) && println ERROR "\n${FG_RED}ERROR${NC}: failure during token-metadata-creator draft:\n${meta_file}" && popd >/dev/null && waitForInput && continue
                    println DEBUG " ${FG_GREEN}OK${NC}!"
                    
                    # Update the sequence number if needed
                    if [[ ${sequence_number} -ne 0 ]]; then
                      println DEBUG false "Updating sequence number to ${FG_LBLUE}${sequence_number}${NC} ..."
                      ! sed -i "s/\"sequenceNumber\":\ .*,/\"sequenceNumber\":\ ${sequence_number},/g" ${meta_file} && popd >/dev/null && waitForInput && continue
                      println DEBUG " ${FG_GREEN}OK${NC}!"
                    fi
                    
                    # Signing draft file with policy signing key
                    println DEBUG false "Signing draft file with policy signing key ..."
                    ! meta_file=$(token-metadata-creator entry ${asset_subject} -a "${policy_sk_file}" 2>&1) && println ERROR "\n${FG_RED}ERROR${NC}: failure during token-metadata-creator signing:\n${meta_file}" && popd >/dev/null && waitForInput && continue
                    println DEBUG " ${FG_GREEN}OK${NC}!"
                    
                    # Finalizing the draft file
                    println DEBUG false "Finalizing the draft file ..."
                    ! meta_file=$(token-metadata-creator entry ${asset_subject} --finalize 2>&1) && println ERROR "\n${FG_RED}ERROR${NC}: failure during token-metadata-creator finalize:\n${meta_file}" && popd >/dev/null && waitForInput && continue
                    println DEBUG " ${FG_GREEN}OK${NC}!"
                    
                    # Validating the final metadata registry submission file
                    println DEBUG false "Validating the final metadata registry submission file ..."
                    ! output=$(token-metadata-creator validate ${meta_file} 2>&1) && println ERROR "\n${FG_RED}ERROR${NC}: failure during token-metadata-creator validation:\n${output}" && popd >/dev/null && waitForInput && continue
                    println DEBUG " ${FG_GREEN}OK${NC}!"
                    
                    popd &>/dev/null || println ERROR "\n${FG_RED}ERROR${NC}: unable to return to previous directory!"
                    
                    # Update .asset file with registered metadata
                    assetFileJSON=$(cat "${asset_file}")
                    assetFileJSON=$(jq ". += {metadata: {name: \"${meta_name}\", description: \"${meta_desc}\", ticker: \"${meta_ticker}\", url: \"${meta_url}\", logo: \"${meta_logo}\", sequenceNumber: \"${sequence_number}\"} } " <<< ${assetFileJSON})
                    assetFileJSON=$(jq ". += {lastUpdate: \"$(date -R)\", lastAction: \"created Cardano Token Registry submission file\"}" <<< ${assetFileJSON})
                    echo -e "${assetFileJSON}" > "${asset_file}"
                    
                    echo
                    println "Cardano Metadata Registry submission file successfully created!"
                    println "Available at: ${policy_folder}/${meta_file}"
                    case ${NWMAGIC} in
                      764824073)  # mainnet
                        println "\nPlease follow directions on CF Token Registry GitHub site to create a PR for the generated metadata file"
                        println "https://github.com/cardano-foundation/cardano-token-registry/wiki/How-to-submit-an-entry-to-the-registry"
                        ;;
                      *) # public testnet
                        println "\nPlease create a PR on IOHK Metadata Registry TestNet GitHub site for the generated metadata file"
                        println "https://github.com/input-output-hk/metadata-registry-testnet"
                        ;;
                    esac
                    
                    waitForInput && continue
                    
                    ;; ###################################################################
                esac # advanced >> multi-asset sub OPERATION
              done # Multi-Asset loop
              ;; ###################################################################
            del-keys)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> ADVANCED >> DELETE PRIVATE KEYS"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              println DEBUG "The following files will be removed"
              println DEBUG "Wallet ${FG_LGRAY}${WALLET_PAY_SK_FILENAME}${NC} / ${FG_LGRAY}${WALLET_STAKE_SK_FILENAME}${NC}"
              println DEBUG "Pool   ${FG_LGRAY}${POOL_COLDKEY_SK_FILENAME}${NC}"
              [[ -d "${ASSET_FOLDER}" ]] && println DEBUG "Asset  ${FG_LGRAY}${ASSET_POLICY_SK_FILENAME}${NC}"
              echo
              println DEBUG "${FG_RED}Do you acknowledge that you have already taken a full backup, and are OK to simply delete the private keys? There is no going back !!!${NC}"
              select_opt "[n] No" "[y] Yes"
              case $? in
                0) continue ;;
                1) : ;; # do nothing
              esac
              echo
              println DEBUG "${FG_YELLOW}Please confirm!${NC} If unsure, cancel and verify that you have a valid backup. Continue with delete action?"
              select_opt "[n] No" "[y] Yes"
              case $? in
                0) continue ;;
                1) : ;; # do nothing
              esac
              echo
              println DEBUG "Delete encrypted keys as well?"
              select_opt "[n] No" "[y] Yes"
              case $? in
                0) enc_postfix="" ;;
                1) enc_postfix="*" ;;
              esac
              echo
              key_del_cnt=0
              while IFS= read -r -d '' file; do
                unlockFile "${file}" && safeDel "${file}" && ((key_del_cnt++))
              done < <(find "${WALLET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${WALLET_PAY_SK_FILENAME}${enc_postfix}" -print0 2>/dev/null)
              while IFS= read -r -d '' file; do
                unlockFile "${file}" && safeDel "${file}" && ((key_del_cnt++))
              done < <(find "${WALLET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${WALLET_STAKE_SK_FILENAME}${enc_postfix}" -print0 2>/dev/null)
              while IFS= read -r -d '' file; do
                unlockFile "${file}" && safeDel "${file}" && ((key_del_cnt++))
              done < <(find "${POOL_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${POOL_COLDKEY_SK_FILENAME}${enc_postfix}" -print0 2>/dev/null)
              while IFS= read -r -d '' file; do
                unlockFile "${file}" && safeDel "${file}" && ((key_del_cnt++))
              done < <(find "${ASSET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${ASSET_POLICY_SK_FILENAME}${enc_postfix}" -print0 2>/dev/null)
              if [[ ${key_del_cnt} -eq 0 ]]; then
                println "No private keys found!"
              else
                println "\n${FG_LBLUE}${key_del_cnt}${NC} private key(s) found and deleted!"
              fi
              waitForInput && continue
              ;; ###################################################################
          esac # advanced sub OPERATION
        done # Advanced loop
        ;; ###################################################################
    esac # main OPERATION
  done # main loop
}

##############################################################

main "$@"
