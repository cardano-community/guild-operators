#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086,SC2154,SC2034,SC2012,SC2140,SC2028,SC1091,SC2206

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#TIMEOUT_NO_OF_SLOTS=600 # used when waiting for a new block to be created

# Log CNTools activities
# LOG_DIR set in env file
#CNTOOLS_LOG="${LOG_DIR}/cntools-history.log"

# kes rotation warning (in seconds)
# if disabled KES check will be skipped on startup
#CHECK_KES=false
#KES_ALERT_PERIOD=172800 # default 2 days
#KES_WARNING_PERIOD=604800 # default 7 days

# Default Transaction TTL (slots after which transaction will expire from queue) to use
#TX_TTL=3600

# Limit for extended wallet selection menu filtering (balance check and delegation status)
# If more wallets exist than limit set these checks will be disabled to improve performance
#WALLET_SELECTION_FILTER_LIMIT=10

# Enable or disable chattr used to protect keys from being overwritten [true|false] (not supported on all systems)
# If disabled standard read-only permission is set instead
#ENABLE_CHATTR=true

# Enable or disable dialog used to help in file/dir selection by providing a gui to see available files and folders. [true|false] (not supported on all systems)
# If disabled standard tty input is used
#ENABLE_DIALOG=false

# Enable advanced/developer features like metadata transactions, asset management etc. [true|false] (not needed for SPO usage)
#ENABLE_ADVANCED=false

# Price fetching currency. Disable by setting value 'off' [off|usd|eur|...] (default: off) (https://api.coingecko.com/api/v3/simple/supported_vs_currencies)
#CURRENCY=usd

# Runtime mode, offline | local | light (default local)
# CNTOOLS_MODE=local

# Project Catalyst API (only for mainnet)
#CATALYST_API=https://api.projectcatalyst.io/api/v1

# Url for transaction lookup on submit, __tx_id__ replaced by transaction hash
#EXPLORER_TX="https://adastat.net/transactions/__tx_id__"

######################################
# Do NOT modify code below           #
######################################

########## Global tasks ###########################################

# General exit handler
cleanup() {
  sleep 0.1
  [[ -n $1 ]] && err=$1 || err=$?
  [[ $err -eq 0 ]] && clear
  [[ -n ${exit_msg} ]] && echo -e "\n${exit_msg}\n" || echo -e "\nCNTools terminated, cleaning up...\n"
  tput cnorm # restore cursor
  tput sgr0  # turn off all attributes
  pkill -TERM -P ${$} &>/dev/null # kill all child processes of CNTools script
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
		
		-n    Local mode   - run CNTools in local node mode (default)
		-l    Light mode   - run CNTools using Koios query layer for full functionallity without a local node
		-o    Offline mode - run CNTools with a limited set of functionallity without external communication useful for air-gapped mode
		-a    Enable advanced/developer features like metadata transactions, asset management etc (not needed for SPO usage)
		-u    Skip script update check overriding UPDATE_CHECK value in env
		-b    Run CNTools and look for updates on alternate branch instead of master (only for testing/development purposes)
		-v    Print CNTools version
		
		EOF
}

ADVANCED_MODE="false"
SKIP_UPDATE=N
PRINT_VERSION="false"
PARENT="$(dirname $0)"
[[ -f "${PARENT}"/.env_branch ]] && BRANCH="$(cat "${PARENT}"/.env_branch)" || BRANCH="master"

# save launch params
arg_copy=("$@")

while getopts :nolaub:v opt; do
  case ${opt} in
    n ) CNTOOLS_MODE="LOCAL" ;;
    o ) CNTOOLS_MODE="OFFLINE" ;;
    l ) CNTOOLS_MODE="LIGHT" ;;
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

# Source env file in normal mode with node connection, else offline mode
if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
  . "${PARENT}"/env || myExit 1
else
  . "${PARENT}"/env offline || myExit 1
fi

# Source cntools.library to populate defaults for CNTools
. "${PARENT}"/cntools.library || myExit 1

# If light mode, test if koios is reachable, otherwise - unset KOIOS_API
if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
  test_koios
  [[ -z ${KOIOS_API} ]] && myExit 1 "ERROR: Koios query test failed, unable to launch CNTools in light mode utilizing Koios query layer\n\n${launch_modes_info}"
fi

[[ ${CNTOOLS_MODE} != "LIGHT" ]] && unset KOIOS_API

[[ ${PRINT_VERSION} = "true" ]] && myExit 0 "CNTools v${CNTOOLS_VERSION} (branch: $([[ -f "${PARENT}"/.env_branch ]] && cat "${PARENT}"/.env_branch || echo "master"))"

# Do some checks when run in connected(local|light) mode
if [[ ${CNTOOLS_MODE} != "OFFLINE" ]]; then
  # check to see if there are any updates available
  clear
  if [[ ${UPDATE_CHECK} = Y && ${SKIP_UPDATE} != Y ]]; then 

    echo "Checking for script updates..."

    # Check availability of checkUpdate function
    if [[ ! $(command -v checkUpdate) ]]; then
      myExit 1 "\nCould not find checkUpdate function in env, make sure you're using official docos for installation!"
    fi

    # check for env update
    OFFLINE_MODE=N
    ENV_UPDATED=N
    checkUpdate env N N N
    case $? in
      1) ENV_UPDATED=Y ;;
      2) myExit 1 "ERROR: Was unable to check for updates on previous run querying from github, please retry!";;
    esac

    # source common env variables in case it was updated
    if [[ ${ENV_UPDATED} = Y ]]; then
      [[ ${CNTOOLS_MODE} = "LOCAL" ]] && . "${PARENT}"/env || . "${PARENT}"/env offline
      case $? in
        1) myExit 1 "ERROR: CNTools failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" ;;
        2) clear ;;
      esac
      [[ ${CNTOOLS_MODE} != "LIGHT" ]] && unset KOIOS_API
    fi
    
    # check for cntools update
    checkUpdate "${PARENT}"/cntools.library "${ENV_UPDATED}" Y N
    case $? in
      1) checkUpdate "${PARENT}"/cntools.sh Y
         if [[ $? = 2 ]]; then
           echo -e "\n${FG_RED}ERROR${NC}: Update check of cntools.sh against GitHub failed!"
           waitToProceed
         fi
         $0 "${arg_copy[@]}" "-u"; myExit 1 ;; # re-launch script with same args skipping update check
      2) echo -e "\n${FG_RED}ERROR${NC}: Update check of cntools.library against GitHub failed!"
         waitToProceed ;;
    esac
  fi

  # check if CNTools was recently updated, if so show whats new
  if curl -s -f -m ${CURL_TIMEOUT} -o "${TMP_DIR}"/cntools-changelog.md "${URL_DOCS}/cntools-changelog.md"; then
    if ! cmp -s "${TMP_DIR}"/cntools-changelog.md "${PARENT}/cntools-changelog.md"; then
      # Latest changes not shown, show whats new and copy changelog
      clear
      if [[ ! -f "${PARENT}/cntools-changelog.md" ]]; then
        # special case for first installation or 5.0.0 upgrade, print release notes until previous major version
        echo -e "~ CNTools - What's New ~\n\n" "$(sed -n "/\[${CNTOOLS_MAJOR_VERSION}\.${CNTOOLS_MINOR_VERSION}\.${CNTOOLS_PATCH_VERSION}\]/,/\[$((CNTOOLS_MAJOR_VERSION-1))\.[0-9]\.[0-9]\]/p" "${TMP_DIR}"/cntools-changelog.md | head -n -2)" "\n [Press 'q' to quit and proceed to CNTools main menu]\n" | less -X
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

# check if there are pools in need of KES key rotation
clear
kes_rotation_needed="no"
if [[ ${CHECK_KES} = true ]]; then

  while IFS= read -r -d '' pool; do
    if [[ ! -f "${pool}/${POOL_CURRENT_KES_START}" ]]; then
      continue
    fi

    unset remaining_kes_periods
    pool_kes_start="$(cat "${pool}/${POOL_CURRENT_KES_START}")"  
  
    if ! kesExpiration ${pool_kes_start}; then println ERROR "${FG_RED}ERROR${NC}: failure during KES calculation for ${FG_GREEN}$(basename ${pool})${NC}" && waitToProceed && continue; fi

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
  [[ ${kes_rotation_needed} = "yes" ]] && waitToProceed
  
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
    if [[ ${CNTOOLS_MODE} != "OFFLINE" ]]; then
      [[ ${CNTOOLS_MODE} = "LOCAL" ]] && getNodeMetrics
      getPriceInfo
      updateProtocolParams
    fi
    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println "$(printf " >> Koios CNTools v%s - %s - ${CNTOOLS_MODE_COLOR}%s${NC} <<" "${CNTOOLS_VERSION}" "${NETWORK_NAME}" "${CNTOOLS_MODE}")"
    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println OFF " Main Menu    Telegram Announcement / Support channel: ${FG_YELLOW}t.me/CardanoKoios/9759${NC}\n"\
			" ) Wallet      - create, show, remove and protect wallets"\
			" ) Funds       - send, withdraw and delegate"\
			" ) Pool        - pool creation and management"\
			" ) Transaction - Sign and Submit a cold transaction (hybrid/offline mode)"\
			" ) Vote        - project funding (Catalyst) and blockchain governance"\
			"$([[ -f "${BLOCKLOG_DB}" ]] && echo " ) Blocks      - show core node leader schedule & block production statistics")"\
			" ) Backup      - backup & restore of wallet/pool/config"\
			"$([[ ${ADVANCED_MODE} = true ]] && echo " ) Advanced    - Developer and advanced features: metadata, assets, ...")"\
			" ) Refresh     - reload home screen content"\
			"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println DEBUG "$(printf "%84s" "Epoch $(getEpoch) - $(timeLeft "$(timeUntilNextEpoch)") until next")"
    if [[ ${CNTOOLS_MODE} != "LOCAL" ]]; then
      println DEBUG " What would you like to do?"
    else
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
    if [[ -n ${price_now} ]]; then
      getDecimalPlaces ${price_now}
      decimals=$?
      price_str="1 ADA = $(LC_NUMERIC=C printf "%.${decimals}f" "${price_now}") ${CURRENCY^^}"
      if [[ ${price_24h:0:1} = '-' ]]; then
        println DEBUG "$(printf "%$((84-${#price_24h}-9))s (24h: ${FG_RED}%s${NC}%%)" "${price_str}" "${price_24h}")"
      else
        println DEBUG "$(printf "%$((84-${#price_24h}-9))s (24h: ${FG_GREEN}%s${NC}%%)" "${price_str}" "${price_24h}")"
      fi
    else
      echo
    fi
    select_opt "[w] Wallet" "[f] Funds" "[p] Pool" "[t] Transaction" "[v] Vote" "$([[ -f "${BLOCKLOG_DB}" ]] && echo "[b] Blocks")" "[z] Backup & Restore" "$([[ ${ADVANCED_MODE} = true ]] && echo "[a] Advanced")" "[r] Refresh" "[q] Quit"
    case ${selected_value} in
      "[w]"*) OPERATION="wallet" ;;
      "[f]"*) OPERATION="funds" ;;
      "[p]"*) OPERATION="pool" ;;
      "[t]"*) OPERATION="transaction" ;;
      "[v]"*) OPERATION="vote" ;;
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
						" ) Import      - import a 24/15 mnemonic or Ledger/Trezor HW wallet"\
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
              while true; do # Wallet >> New loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> WALLET >> NEW"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Wallet New\n"\
                  " ) Mnemonic - based on 24 word generated passphrase (recommended)"\
                  " ) CLI      - one-time generated keys"\
                  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select Wallet Creation Type\n"
                select_opt "[m] Mnemonic" "[c] CLI" "[b] Back" "[h] Home"
                case $? in
                  0) SUBCOMMAND="mnemonic" ;;
                  1) SUBCOMMAND="cli" ;;
                  2) break ;;
                  3) break 2 ;;
                esac
                case $SUBCOMMAND in
                  mnemonic)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> WALLET >> NEW >> MNEMONIC"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    createNewWallet || continue
                    unset mnemonic
                    createMnemonicWallet || continue
                    echo
                    println "Wallet Imported : ${FG_GREEN}${wallet_name}${NC}"
                    println "Address         : ${FG_LGRAY}${base_addr}${NC}"
                    println "Payment Address : ${FG_LGRAY}${pay_addr}${NC}"
                    echo
                    word_len=0
                    for word in "${words[@]}"; do
                      [[ ${#word} -gt ${word_len} ]] && word_len=${#word}
                    done
                    println DEBUG "${FG_YELLOW}IMPORTANT!${NC} Please write down and store below words in a secure place to be able to restore wallet at a later time."
                    for i in "${!words[@]}"; do
                      idx=$(( i + 1 ))
                      printf "%2s: ${FG_GREEN}%-${word_len}s${NC}  " "$idx" "${words[$i]}"
                      [[ $(( idx % 4 )) -eq 0 ]] && echo
                    done
                    unset words
                    echo
                    printWalletInfo
                    waitToProceed && continue
                    ;; ###################################################################
                  cli)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> WALLET >> NEW >> CLI"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    createNewWallet || continue
                    # Wallet key filenames
                    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
                    payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
                    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
                    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
                    drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_VK_FILENAME}"
                    drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_SK_FILENAME}"
                    cc_cold_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_COLD_VK_FILENAME}"
                    cc_cold_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_COLD_SK_FILENAME}"
                    cc_hot_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_HOT_VK_FILENAME}"
                    cc_hot_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_HOT_SK_FILENAME}"
                    ms_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_SK_FILENAME}"
                    ms_payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
                    ms_stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_SK_FILENAME}"
                    ms_stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
                    ms_drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_SK_FILENAME}"
                    ms_drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
                    if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -type f -print0 | wc -c) -gt 0 ]]; then
                      println "${FG_RED}WARN${NC}: A wallet ${FG_GREEN}$wallet_name${NC} already exists"
                      println "      Choose another name or delete the existing one"
                      waitToProceed && continue
                    fi
                    println ACTION "${CCLI} ${NETWORK_ERA} address key-gen --verification-key-file ${payment_vk_file} --signing-key-file ${payment_sk_file}"
                    if ! stdout=$(${CCLI} ${NETWORK_ERA} address key-gen --verification-key-file "${payment_vk_file}" --signing-key-file "${payment_sk_file}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during payment key creation!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && continue
                    fi
                    println ACTION "${CCLI} ${NETWORK_ERA} stake-address key-gen --verification-key-file ${stake_vk_file} --signing-key-file ${stake_sk_file}"
                    if ! stdout=$(${CCLI} ${NETWORK_ERA} stake-address key-gen --verification-key-file "${stake_vk_file}" --signing-key-file "${stake_sk_file}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during stake key creation!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && continue
                    fi
                    println ACTION "${CCLI} conway governance drep key-gen --verification-key-file ${drep_vk_file} --signing-key-file ${drep_sk_file}"
                    if ! stdout=$(${CCLI} conway governance drep key-gen --verification-key-file "${drep_vk_file}" --signing-key-file "${drep_sk_file}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during governance drep key creation!\n${stdout}"; waitToProceed && continue
                    fi
                    println ACTION "${CCLI} conway governance committee key-gen-cold --cold-verification-key-file ${cc_cold_vk_file} --cold-signing-key-file ${cc_cold_sk_file}"
                    if ! stdout=$(${CCLI} conway governance committee key-gen-cold --cold-verification-key-file "${cc_cold_vk_file}" --cold-signing-key-file "${cc_cold_sk_file}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during governance committee cold key creation!\n${stdout}"; waitToProceed && continue
                    fi
                    println ACTION "${CCLI} conway governance committee key-gen-hot --verification-key-file ${cc_hot_vk_file} --signing-key-file ${cc_hot_sk_file}"
                    if ! stdout=$(${CCLI} conway governance committee key-gen-hot --verification-key-file "${cc_hot_vk_file}" --signing-key-file "${cc_hot_sk_file}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during governance committee hot key creation!\n${stdout}"; waitToProceed && continue
                    fi
                    println ACTION "${CCLI} ${NETWORK_ERA} address key-gen --verification-key-file ${ms_payment_vk_file} --signing-key-file ${ms_payment_sk_file}"
                    if ! stdout=$(${CCLI} ${NETWORK_ERA} address key-gen --verification-key-file "${ms_payment_vk_file}" --signing-key-file "${ms_payment_sk_file}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig payment key creation!\n${stdout}"; waitToProceed && continue
                    fi
                    println ACTION "${CCLI} ${NETWORK_ERA} stake-address key-gen --verification-key-file ${ms_stake_vk_file} --signing-key-file ${ms_stake_sk_file}"
                    if ! stdout=$(${CCLI} ${NETWORK_ERA} stake-address key-gen --verification-key-file "${ms_stake_vk_file}" --signing-key-file "${ms_stake_sk_file}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig stake key creation!\n${stdout}"; waitToProceed && continue
                    fi
                    println ACTION "${CCLI} conway governance drep key-gen --verification-key-file ${ms_drep_vk_file} --signing-key-file ${ms_drep_sk_file}"
                    if ! stdout=$(${CCLI} conway governance drep key-gen --verification-key-file "${ms_drep_vk_file}" --signing-key-file "${ms_drep_sk_file}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig governance drep key creation!\n${stdout}"; waitToProceed && continue
                    fi
                    chmod 600 "${WALLET_FOLDER}/${wallet_name}/"*
                    getBaseAddress ${wallet_name}
                    getPayAddress ${wallet_name}
                    getRewardAddress ${wallet_name}
                    getCredentials ${wallet_name}
                    println "New Wallet      : ${FG_GREEN}${wallet_name}${NC}"
                    println "Address         : ${FG_LGRAY}${base_addr}${NC}"
                    println "Payment Address : ${FG_LGRAY}${pay_addr}${NC}"
                    println DEBUG "\nYou can now send and receive ADA using the above addresses."
                    println DEBUG "Note that Payment Address will not take part in staking."
                    println DEBUG "Wallet will be automatically registered on chain if you\nchoose to delegate or pledge wallet when registering a stake pool."
                    waitToProceed && continue
                    ;; ###################################################################
                esac # wallet >> new sub OPERATION
              done # Wallet >> new loop
              ;; ###################################################################
            import)
              while true; do # Wallet >> Import loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> WALLET >> IMPORT"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Wallet Import\n"\
									" ) Mnemonic  - 24 or 15 word mnemonic"\
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
                    createNewWallet || continue
                    getAnswerAnyCust mnemonic false "24 or 15 word mnemonic(space separated)"
                    echo
                    IFS=" " read -r -a words <<< "${mnemonic}"
                    if [[ ${#words[@]} -ne 24 ]] && [[ ${#words[@]} -ne 15 ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: 24 or 15 words expected, found ${FG_RED}${#words[@]}${NC}"
                      echo && safeDel "${WALLET_FOLDER}/${wallet_name}"
                      unset mnemonic; unset words
                      waitToProceed && continue
                    fi
                    createMnemonicWallet || continue
                    echo
                    println "Wallet Imported : ${FG_GREEN}${wallet_name}${NC}"
                    println "Address         : ${FG_LGRAY}${base_addr}${NC}"
                    println "Payment Address : ${FG_LGRAY}${pay_addr}${NC}"
                    echo
                    printWalletInfo
                    waitToProceed && continue
                    ;; ###################################################################
                  hardware)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> WALLET >> IMPORT >> HARDWARE WALLET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    println DEBUG "${FG_BLUE}NOTE${NC}: Make sure your hardware wallet supported by Cardano and cardano-hw-cli utility"
                    echo
                    if ! cmdAvailable "cardano-hw-cli" &>/dev/null; then
                      println ERROR "${FG_RED}ERROR${NC}: cardano-hw-cli not found in path or executable permission not set."
                      println ERROR "Please run '${FG_YELLOW}guild-deploy.sh -s w${NC}' to add hardware wallet support and install Vaccumlabs cardano-hw-cli, '${FG_YELLOW}guild-deploy.sh -h${NC}' shows all available options"
                      waitToProceed && continue
                    fi
                    if ! HWCLIversionCheck; then waitToProceed && continue; fi
                    createNewWallet || continue
                    getCustomDerivationPath || continue
                    derivation_path_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DERIVATION_PATH_FILENAME}"
                    echo "1852H/1815H/${acct_idx}H/x/${key_idx}" > "${derivation_path_file}"
                    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_HW_PAY_SK_FILENAME}"
                    payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
                    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_HW_STAKE_SK_FILENAME}"
                    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
                    drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_HW_DREP_SK_FILENAME}"
                    drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_VK_FILENAME}"
                    cc_cold_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_HW_CC_COLD_SK_FILENAME}"
                    cc_cold_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_COLD_VK_FILENAME}"
                    cc_hot_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_HW_CC_HOT_SK_FILENAME}"
                    cc_hot_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_HOT_VK_FILENAME}"
                    ms_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_HW_PAY_SK_FILENAME}"
                    ms_payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
                    ms_stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_HW_STAKE_SK_FILENAME}"
                    ms_stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
                    ms_drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_HW_DREP_SK_FILENAME}"
                    ms_drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
                    if ! unlockHWDevice "extract ${FG_LGRAY}keys${NC}"; then safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && continue; fi
                    println "Include governance (drep & committee) keys (only Ledger supported)?"
                    select_opt "[n] No" "[y] Yes"
                    case $? in
                      0)
                        HW_DERIVATION_CMD=(
                          cardano-hw-cli address key-gen
                          --path 1852H/1815H/${acct_idx}H/0/${key_idx}
                          --path 1852H/1815H/${acct_idx}H/2/${key_idx}
                          --path 1854H/1815H/${acct_idx}H/0/${key_idx}
                          --path 1854H/1815H/${acct_idx}H/2/${key_idx}
                          --verification-key-file "${payment_vk_file}"
                          --verification-key-file "${stake_vk_file}"
                          --verification-key-file "${ms_payment_vk_file}"
                          --verification-key-file "${ms_stake_vk_file}"
                          --hw-signing-file "${payment_sk_file}"
                          --hw-signing-file "${stake_sk_file}"
                          --hw-signing-file "${ms_payment_sk_file}"
                          --hw-signing-file "${ms_stake_sk_file}"
                        )
                        ;; # do nothing
                      1)
                        HW_DERIVATION_CMD=(
                          cardano-hw-cli address key-gen
                          --path 1852H/1815H/${acct_idx}H/0/${key_idx}
                          --path 1852H/1815H/${acct_idx}H/2/${key_idx}
                          --path 1852H/1815H/${acct_idx}H/3/${key_idx}
                          --path 1852H/1815H/${acct_idx}H/4/${key_idx}
                          --path 1852H/1815H/${acct_idx}H/5/${key_idx}
                          --path 1854H/1815H/${acct_idx}H/0/${key_idx}
                          --path 1854H/1815H/${acct_idx}H/2/${key_idx}
                          --verification-key-file "${payment_vk_file}"
                          --verification-key-file "${stake_vk_file}"
                          --verification-key-file "${drep_vk_file}"
                          --verification-key-file "${cc_cold_vk_file}"
                          --verification-key-file "${cc_hot_sk_file}"
                          --verification-key-file "${ms_payment_vk_file}"
                          --verification-key-file "${ms_stake_vk_file}"
                          --hw-signing-file "${payment_sk_file}"
                          --hw-signing-file "${stake_sk_file}"
                          --hw-signing-file "${drep_sk_file}"
                          --hw-signing-file "${cc_cold_sk_file}"
                          --hw-signing-file "${cc_hot_sk_file}"
                          --hw-signing-file "${ms_payment_sk_file}"
                          --hw-signing-file "${ms_stake_sk_file}"
                        )
                        ;;
                    esac
                    println ACTION "${HW_DERIVATION_CMD[*]}"
                    if ! stdout=$("${HW_DERIVATION_CMD[@]}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && continue
                    fi
                    # make a copy of 1852 DRep keys to 1854 multisig due to lacking HW support
                    cp "${drep_sk_file}" "${ms_drep_sk_file}"
                    cp "${drep_vk_file}" "${ms_drep_vk_file}"
                    jq '.description = "Payment Hardware Verification Key"' "${payment_vk_file}" > "${TMP_DIR}/$(basename "${payment_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${payment_vk_file}").tmp" "${payment_vk_file}"
                    jq '.description = "Stake Hardware Verification Key"' "${stake_vk_file}" > "${TMP_DIR}/$(basename "${stake_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${stake_vk_file}").tmp" "${stake_vk_file}"
                    jq '.description = "Delegate Representative Hardware Verification Key"' "${drep_vk_file}" > "${TMP_DIR}/$(basename "${drep_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${drep_vk_file}").tmp" "${drep_vk_file}"
                    jq '.description = "Constitutional Committee Cold Hardware Verification Key"' "${cc_cold_vk_file}" > "${TMP_DIR}/$(basename "${cc_cold_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${cc_cold_vk_file}").tmp" "${cc_cold_vk_file}"
                    jq '.description = "Constitutional Committee Hot Hardware Verification Key"' "${cc_hot_sk_file}" > "${TMP_DIR}/$(basename "${cc_hot_sk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${cc_hot_sk_file}").tmp" "${cc_hot_sk_file}"
                    jq '.description = "MultiSig Payment Hardware Verification Key"' "${ms_payment_vk_file}" > "${TMP_DIR}/$(basename "${ms_payment_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${ms_payment_vk_file}").tmp" "${ms_payment_vk_file}"
                    jq '.description = "MultiSig Stake Hardware Verification Key"' "${ms_stake_vk_file}" > "${TMP_DIR}/$(basename "${ms_stake_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${ms_stake_vk_file}").tmp" "${ms_stake_vk_file}"
                    jq '.description = "MultiSig Delegate Representative Hardware Verification Key"' "${ms_drep_vk_file}" > "${TMP_DIR}/$(basename "${ms_drep_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${ms_drep_vk_file}").tmp" "${ms_drep_vk_file}"
                    getBaseAddress ${wallet_name}
                    getPayAddress ${wallet_name}
                    getRewardAddress ${wallet_name}
                    getCredentials ${wallet_name}
                    echo
                    println "HW Wallet Imported : ${FG_GREEN}${wallet_name}${NC}"
                    println "Address            : ${FG_LGRAY}${base_addr}${NC}"
                    println "Payment Address    : ${FG_LGRAY}${pay_addr}${NC}"
                    echo
                    printWalletInfo
                    waitToProceed && continue
                    ;; ###################################################################
                esac # wallet >> import sub OPERATION
              done # Wallet >> Import loop
              ;; ###################################################################
            register)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> REGISTER"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "Select wallet to register (only non-registered wallets shown)"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "non-reg"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "non-reg"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              getWalletBalance ${wallet_name} true true false true
              if [[ ${base_lovelace} -gt 0 ]]; then
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Funds in wallet:"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                println DEBUG "Funds for key deposit($(formatLovelace ${KEY_DEPOSIT}) ADA) + transaction fee needed to register the wallet"
                waitToProceed && continue
              fi
              if ! registerStakeWallet ${wallet_name} "true"; then
                waitToProceed && continue
              fi
              println "${FG_GREEN}${wallet_name}${NC} successfully registered on chain!"
              waitToProceed && continue
              ;; ###################################################################
            deregister)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> DE-REGISTER"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "Select wallet to de-register (only registered wallets shown)"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "reg"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "reg"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              getWalletRewards ${wallet_name}
              if [[ "${reward_lovelace}" -gt 0 ]]; then
                println "\n${FG_YELLOW}WARN${NC}: wallet has unclaimed rewards, please use 'Funds >> Withdraw Rewards' before de-registration to claim your rewards"
                waitToProceed && continue
              fi
              getWalletBalance ${wallet_name} true true false true
              if [[ ${base_lovelace} -le 0 ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                println ERROR "Funds for transaction fee needed to deregister the wallet"
                waitToProceed && continue
              fi
              if ! deregisterStakeWallet; then
                [[ -f ${stake_dereg_file} ]] && rm -f ${stake_dereg_file}
                waitToProceed && continue
              fi
              echo
              if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
              echo
              println "${FG_GREEN}${wallet_name}${NC} successfully de-registered from chain!"
              println "Key deposit fee that will be refunded : ${FG_LBLUE}$(formatLovelace ${KEY_DEPOSIT})${NC} ADA"
              waitToProceed && continue
              ;; ###################################################################
            list)
              clear
              [[ ${CNTOOLS_MODE} != "OFFLINE" ]] && getPriceInfo
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> LIST"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, wallet balance not shown!"
              fi
              if [[ -n ${KOIOS_API} ]]; then
                tput sc
                println OFF "\n${FG_YELLOW}> Querying Koios API for wallet information${NC}"
                addr_list=()
                reward_addr_list=()
                while IFS= read -r -d '' wallet; do
                  wallet_name=$(basename ${wallet})
                  getBaseAddress ${wallet_name}
                  [[ -n ${base_addr} ]] && addr_list+=(${base_addr})
                  getPayAddress ${wallet_name}
                  [[ -n ${pay_addr} ]] && addr_list+=(${pay_addr})
                  getRewardAddress ${wallet_name}
                  [[ -n ${reward_addr} ]] && reward_addr_list+=(${reward_addr})
                done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0)
                [[ ${#addr_list[@]} -gt 0 ]] && getBalanceKoios
                [[ ${#reward_addr_list[@]} -gt 0 ]] && getRewardInfoKoios
                tput rc && tput ed
              fi

              while IFS= read -r -d '' wallet; do
                wallet_name=$(basename ${wallet})
                enc_files=$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c)
                if [[ ${CNTOOLS_MODE} != "OFFLINE" ]] && isWalletRegistered ${wallet_name}; then registered="yes"; else registered="no"; fi
                echo
                if [[ ${registered} = "yes" ]]; then
                  postfix="- ${FG_LBLUE}REGISTERED${NC}"
                else
                  postfix="- ${FG_LGRAY}UNREGISTERED${NC}"
                fi
                getWalletType ${wallet_name}
                [[ $? -eq 5 ]] && postfix="${postfix} (${FG_LGRAY}MultiSig${NC})"
                [[ ${enc_files} -gt 0 ]] && postfix="${postfix} (${FG_YELLOW}encrypted${NC})"
                if [[ ${enc_files} -gt 0 && ${registered} = "yes" ]]; then
                  println "${FG_GREEN}${wallet_name}${NC} - ${FG_LGRAY}REGISTERED${NC} (${FG_YELLOW}encrypted${NC})"
                elif [[ ${registered} = "yes" ]]; then
                  println "${FG_GREEN}${wallet_name}${NC} - ${FG_LGRAY}REGISTERED${NC}"
                elif [[ ${enc_files} -gt 0 ]]; then
                  println "${FG_GREEN}${wallet_name}${NC} (${FG_YELLOW}encrypted${NC})"
                else
                  println "${FG_GREEN}${wallet_name}${NC}"
                fi
                getWalletType ${wallet_name}
                case $? in
                  0) println "$(printf "%-15s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Type" "Hardware")" ;;
                  1) println "$(printf "%-15s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Type" "CLI")" ;;
                  5) println "$(printf "%-15s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Type" "MultiSig")" ;;
                esac
                getBaseAddress ${wallet_name}
                getPayAddress ${wallet_name}
                if [[ -z ${base_addr} && -z ${pay_addr} ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: wallet missing pay/base addr files or vkey/script files to generate them!"
                  continue
                fi
                if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                  [[ -n ${base_addr} ]] && println "$(printf "%-15s : ${FG_LGRAY}%s${NC}" "Address" "${base_addr}")"
                  [[ -n ${pay_addr} ]] && println "$(printf "%-15s : ${FG_LGRAY}%s${NC}" "Payment Addr" "${pay_addr}")"
                else
                  if [[ -n ${base_addr} ]]; then
                    lovelace=0
                    asset_cnt=0
                    if [[ -n ${KOIOS_API} ]]; then
                      for key in "${!assets[@]}"; do
                        [[ ${key} = "${base_addr},lovelace" ]] && lovelace=${assets["${base_addr},lovelace"]} && continue
                        [[ ${key} = "${base_addr},"* ]] && ((asset_cnt++))
                      done
                    else
                      getBalance ${base_addr}
                      lovelace=${assets[lovelace]}
                      asset_cnt=$(( ${#assets[@]} - 1 ))
                    fi
                    getPriceString ${lovelace}
                    println "$(printf "%-15s : ${FG_LGRAY}%s${NC}" "Address"  "${base_addr}")"
                    if [[ ${asset_cnt} -eq 0 ]]; then
                      println "$(printf "%-15s : ${FG_LBLUE}%s${NC} ADA${price_str}" "Funds"  "$(formatLovelace ${lovelace})")"
                    else
                      println "$(printf "%-15s : ${FG_LBLUE}%s${NC} ADA${price_str} - ${FG_LBLUE}%s${NC} additional asset(s) on address! [WALLET >> SHOW for details]" "Base Funds" "$(formatLovelace ${lovelace})" "${asset_cnt}")"
                    fi
                  fi
                  if [[ -n ${pay_addr} ]]; then
                    lovelace=0
                    asset_cnt=0
                    if [[ -n ${KOIOS_API} ]]; then
                      for key in "${!assets[@]}"; do
                        [[ ${key} = "${pay_addr},lovelace" ]] && lovelace=${assets["${pay_addr},lovelace"]} && continue
                        [[ ${key} = "${pay_addr},"* ]] && ((asset_cnt++))
                      done
                    else
                      getBalance ${pay_addr}
                      lovelace=${assets[lovelace]}
                      asset_cnt=$(( ${#assets[@]} - 1 ))
                    fi
                    getPriceString ${lovelace}
                    if [[ ${lovelace} -gt 0 ]]; then
                      println "$(printf "%-15s : ${FG_LGRAY}%s${NC}" "Payment Addr" "${pay_addr}")"
                      if [[ ${asset_cnt} -eq 0 ]]; then
                        println "$(printf "%-15s : ${FG_LBLUE}%s${NC} ADA${price_str}" "Payment Funds" "$(formatLovelace ${lovelace})")"
                      else
                        println "$(printf "%-15s : ${FG_LBLUE}%s${NC} ADA${price_str} - ${FG_LBLUE}%s${NC} additional asset(s) on address! [WALLET >> SHOW for details]" "Payment Funds" "$(formatLovelace ${lovelace})" "${asset_cnt}")"
                      fi
                    fi
                  fi
                  if [[ -n ${KOIOS_API} ]]; then
                    [[ -v rewards_available[${reward_addr}] ]] && reward_lovelace=${rewards_available[${reward_addr}]} || reward_lovelace=0
                    pool_delegation=${pool_delegations[${reward_addr}]}
                  else
                    getWalletRewards ${wallet_name}
                  fi
                  if [[ -n ${pool_delegation} ]]; then
                    getPriceString ${reward_lovelace}
                    println "$(printf "%-15s : ${FG_LBLUE}%s${NC} ADA${price_str}" "Rewards" "$(formatLovelace ${reward_lovelace})")"
                    unset poolName
                    while IFS= read -r -d '' pool; do
                      getPoolID "$(basename ${pool})"
                      if [[ "${pool_id_bech32}" = "${pool_delegation}" ]]; then
                        poolName=$(basename ${pool}) && break
                      fi
                    done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
                    println "${FG_RED}Delegated${NC} to ${FG_GREEN}${poolName}${NC} ${FG_LGRAY}(${pool_delegation})${NC}"
                  fi
                fi
              done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
              waitToProceed && continue
              ;; ###################################################################
            show)
              clear
              [[ ${CNTOOLS_MODE} != "OFFLINE" ]] && getPriceInfo
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> SHOW"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, limited wallet info shown!"
              fi
              tput sc
              selectWallet "none"
              case $? in
                1) waitToProceed; continue ;;
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
                println ERROR "\n${FG_RED}ERROR${NC}: wallet missing pay/base addr files or vkey/script files to generate them!"
                waitToProceed && continue
              fi
              getRewardAddress ${wallet_name}
              if [[ -n ${KOIOS_API} ]]; then
                tput sc
                println OFF "\n${FG_YELLOW}> Querying Koios API for wallet information${NC}"
                addr_list=()
                [[ -n ${base_addr} ]] && addr_list+=("${base_addr}")
                [[ -n ${pay_addr} ]] && addr_list+=("${pay_addr}")
                reward_addr_list=("${reward_addr}")
                [[ ${#addr_list[@]} -gt 0 ]] && getBalanceKoios
                [[ ${#reward_addr_list[@]} -gt 0 ]] && getRewardInfoKoios
                tput rc && tput ed
              fi
              total_lovelace=0
              if [[ ${CNTOOLS_MODE} != "OFFLINE" ]]; then
                for i in {1..2}; do
                  if [[ $i -eq 1 ]]; then
                    [[ -z ${base_addr} ]] && continue
                    address_type="Base"
                    address=${base_addr}
                    if [[ -n ${KOIOS_API} ]]; then
                      base_lovelace=${assets["${base_addr},lovelace"]}
                    else
                      getBalance ${base_addr}
                      base_lovelace=${assets[lovelace]}
                    fi
                    total_lovelace=$((total_lovelace + base_lovelace))
                  else
                    [[ -z ${pay_addr} ]] && continue
                    address_type="Payment"
                    address=${pay_addr}
                    if [[ -n ${KOIOS_API} ]]; then
                      pay_lovelace=${assets["${pay_addr},lovelace"]}
                      [[ ${utxos_cnt["${pay_addr}"]:-0} -eq 0 ]] && continue # Dont print if empty
                    else
                      getBalance ${pay_addr}
                      pay_lovelace=${assets[lovelace]}
                      [[ ${utxo_cnt} -eq 0 ]] && continue # Dont print if empty
                    fi
                    total_lovelace=$((total_lovelace + pay_lovelace))
                  fi

                  echo
                  if [[ -n ${KOIOS_API} ]]; then
                    utxo_cnt=${utxos_cnt["${address}"]:-0}
                    asset_name_maxlen=${asset_name_maxlen_arr["${address}"]:-5}
                    asset_amount_maxlen=${asset_amount_maxlen_arr["${address}"]:-12}
                  fi
                  println "${FG_LBLUE}${utxo_cnt} UTxO(s)${NC} found for ${FG_GREEN}${address_type}${NC} Address!"
                  if [[ ${utxo_cnt} -gt 0 ]]; then
                    echo
                    println DEBUG "$(printf "%-68s ${FG_DGRAY}|${NC} %${asset_name_maxlen}s ${FG_DGRAY}|${NC} %-${asset_amount_maxlen}s\n" "UTxO Hash#Index" "Asset" "Amount")"
                    println DEBUG "${FG_DGRAY}$(printf "%69s+%$((asset_name_maxlen+2))s+%$((asset_amount_maxlen+1))s\n" "" "" "" | tr " " "-")${NC}"
                    mapfile -d '' utxos_sorted < <(printf '%s\0' "${!utxos[@]}" | sort -z)
                    for utxo in "${utxos_sorted[@]}"; do
                      [[ -n ${KOIOS_API} && ${utxo} != "${address},"* ]] && continue
                      IFS='.' read -ra utxo_arr <<< "${utxo#*,}"
                      if [[ ${#utxo_arr[@]} -eq 2 && ${utxo_arr[1]} = " ADA" ]]; then
                        println DEBUG "$(printf "%-68s ${FG_DGRAY}|${NC} ${FG_GREEN}%${asset_name_maxlen}s${NC} ${FG_DGRAY}|${NC} ${FG_LBLUE}%-${asset_amount_maxlen}s${NC}\n" "${utxo_arr[0]}" "ADA" "$(formatLovelace ${utxos["${utxo}"]})")"
                      else
                        [[ ${#utxo_arr[@]} -eq 3 ]] && asset_name="${utxo_arr[2]}" || asset_name=""
                        tname="$(hexToAscii ${asset_name})"
                        tname="${tname//[![:print:]]/}"
                        ! assets_id_bech32=$(getAssetIDBech32 ${utxo_arr[1]} ${asset_name}) && continue 3
                        println DEBUG "$(printf "${FG_DGRAY}%20s${NC}${FG_LGRAY}%-48s${NC} ${FG_DGRAY}|${NC} ${FG_MAGENTA}%${asset_name_maxlen}s${NC} ${FG_DGRAY}|${NC} ${FG_LBLUE}%-${asset_amount_maxlen}s${NC}\n" "Asset Fingerprint: " "${assets_id_bech32}" "${tname}" "$(formatAsset ${utxos["${utxo}"]})")"
                      fi
                    done
                  fi
                  lovelace=0
                  asset_cnt=0
                  if [[ -n ${KOIOS_API} ]]; then
                    for key in "${!assets[@]}"; do
                      [[ ${key} = "${address},lovelace" ]] && lovelace=${assets["${address},lovelace"]}
                      [[ ${key} = "${address},"* ]] && ((asset_cnt++))
                    done
                  else
                    lovelace=${assets[lovelace]}
                    asset_cnt=${#assets[@]}
                  fi
                  if [[ ${asset_cnt} -gt 0 ]]; then
                    println "\nASSET SUMMARY: ${FG_LBLUE}${asset_cnt} Asset-Type(s)${NC}\n"
                    println DEBUG "$(printf "%${asset_amount_maxlen}s ${FG_DGRAY}|${NC} %-${asset_name_maxlen}s%s\n" "Total Amount" "Asset" "$([[ ${asset_cnt} -gt 1 ]] && echo -e " ${FG_DGRAY}|${NC} Asset Fingerprint")")"
                    println DEBUG "${FG_DGRAY}$(printf "%$((asset_amount_maxlen+1))s+%$((asset_name_maxlen+2))s%s\n" "" "" "$([[ ${asset_cnt} -gt 1 ]] && printf "+%57s" "")" | tr " " "-")${NC}"
                    println DEBUG "$(printf "${FG_LBLUE}%${asset_amount_maxlen}s${NC} ${FG_DGRAY}|${NC} ${FG_GREEN}%-${asset_name_maxlen}s${NC}%s\n" "$(formatLovelace ${lovelace})" "ADA" "$([[ ${asset_cnt} -gt 1 ]] && echo -n " ${FG_DGRAY}|${NC}")")"
                    mapfile -d '' assets_sorted < <(printf '%s\0' "${!assets[@]}" | sort -z)
                    for asset in "${assets_sorted[@]}"; do
                      [[ ${asset} = *"lovelace" ]] && continue
                      IFS='.' read -ra asset_arr <<< "${asset#*,}"
                      [[ ${#asset_arr[@]} -eq 1 ]] && asset_name="" || asset_name="${asset_arr[1]}"
                      ! assets_id_bech32=$(getAssetIDBech32 ${asset_arr[0]} ${asset_name}) && assets_id_bech32="?"
                      tname="$(hexToAscii ${asset_name})"
                      tname="${tname//[![:print:]]/}"
                      println DEBUG "$(printf "${FG_LBLUE}%${asset_amount_maxlen}s${NC} ${FG_DGRAY}|${NC} ${FG_MAGENTA}%-${asset_name_maxlen}s${NC} ${FG_DGRAY}|${NC} ${FG_LGRAY}%s${NC}\n" "$(formatAsset ${assets["${asset}"]})" "${tname}" "${assets_id_bech32}")"
                    done
                  fi
                done
                
                println DEBUG "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                if isWalletRegistered ${wallet_name}; then
                  println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_GREEN}%s${NC}" "Registered" "YES")"
                else
                  println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_RED}%s${NC}" "Registered" "NO")"
                fi
              else
                println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Registered" "Unknown")"
              fi

              getWalletType ${wallet_name}
              case $? in
                0) println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Type" "Hardware")" ;;
                1) println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Type" "CLI")" ;;
                5) println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Type" "MultiSig")" ;;
              esac

              derivation_path_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DERIVATION_PATH_FILENAME}"
              if getSavedDerivationPath "${derivation_path_file}"; then
                println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Derivation Path" "${derivation_path}")"
              fi

              if [[ -f ${payment_script_file} ]]; then
                unset timelock_after atleast total_signers script_sig_list
                while read -r _slot; do
                  timelock_after=${_slot}
                  break
                done < <( jq -r '.. | select(.type?=="after") | .slot' "${payment_script_file}" )
                while IFS=',' read -r _required _total _sig_list; do
                  atleast=${_required}
                  total_signers=${_total}
                  IFS=$'\t' read -ra script_sig_list <<< "${_sig_list}"
                  break
                done < <( jq -r '.. | select(.type?=="atLeast") | "\(.required),\(.scripts|length),\(.scripts|map(.keyHash)|@tsv)"' "${payment_script_file}" )
                if [[ -n ${timelock_after} ]]; then
                  timelock_date=$(getDateFromSlot ${timelock_after} '%(%F %T %Z)T')
                  [[ $(getSlotTipRef) -gt ${timelock_after} ]] && timelock_color="${FG_GREEN}" || timelock_color="${FG_YELLOW}"
                  println "$(printf "%-20s ${FG_DGRAY}:${NC} ${timelock_color}%s${NC}" "Time Locked Until" "${timelock_date}")"
                fi
                if [[ -n ${atleast} ]]; then
                  cred_header="MultiSig Creds (${total_signers})"
                  for _sig in "${script_sig_list[@]}"; do
                    unset wallet_str
                    while IFS= read -r -d '' wallet; do
                      getCredentials "$(basename ${wallet})"
                      if [[ ${ms_pay_cred} = "${_sig}" ]]; then
                        wallet_str=" (${FG_GREEN}$(basename ${wallet})${NC})" && break
                      fi
                    done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
                    println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}%s" "${cred_header}" "${_sig}" "${wallet_str}")"
                    unset cred_header
                  done
                  println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Required signers" "${atleast}")"
                fi
              fi

              [[ -n ${base_addr} ]]       && println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Address" "${base_addr}")"
              if [[ -n ${pay_addr} ]]; then
                println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Payment Address" "${pay_addr}")"
              fi
              [[ -n ${reward_addr} ]]     && println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Reward/Stake Address" "${reward_addr}")"
              getCredentials ${wallet_name}
              if [[ -n ${pay_cred} || -n ${stake_cred} || -n ${ms_pay_cred} || -n ${ms_stake_cred} ]]; then
                println "${FG_DGRAY}# Credentials${NC}"
              fi
              [[ -n ${pay_cred} ]]          && println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Payment" "${pay_cred}")"
              [[ -n ${stake_cred} ]]        && println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Stake" "${stake_cred}")"
              [[ -n ${ms_pay_cred} ]]       && println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "MultiSig Payment" "${ms_pay_cred}")"
              [[ -n ${ms_stake_cred} ]]     && println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "MultiSig Stake" "${ms_stake_cred}")"
              [[ -n ${script_pay_cred} ]]   && println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Script Payment" "${script_pay_cred}")"
              [[ -n ${script_stake_cred} ]] && println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Script Stake" "${script_stake_cred}")"

              if [[ ${CNTOOLS_MODE} != "OFFLINE" ]]; then
                println "${FG_DGRAY}# Funds${NC}"
                if [[ -n ${reward_addr} ]]; then
                  if [[ -n ${KOIOS_API} ]]; then
                    [[ -v rewards_available[${reward_addr}] ]] && reward_lovelace=${rewards_available[${reward_addr}]} || reward_lovelace=0
                    pool_delegation=${pool_delegations[${reward_addr}]}
                  else
                    getRewardsFromAddr ${reward_addr}
                  fi
                  total_lovelace=$((total_lovelace + reward_lovelace))
                  getPriceString ${reward_lovelace}
                  println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LBLUE}%s${NC} ADA${price_str}" "Rewards Available" "$(formatLovelace ${reward_lovelace})")"
                fi
                getPriceString ${total_lovelace}
                println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LBLUE}%s${NC} ADA${price_str}" "Funds + Rewards" "$(formatLovelace ${total_lovelace})")"
                if [[ -n ${pool_delegation} ]]; then
                  unset poolName
                  while IFS= read -r -d '' pool; do
                    getPoolID "$(basename ${pool})"
                    if [[ "${pool_id_bech32}" = "${pool_delegation}" ]]; then
                      poolName=$(basename ${pool}) && break
                    fi
                  done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
                  echo
                  println "${FG_RED}Delegated${NC} to ${FG_GREEN}${poolName}${NC} ${FG_LGRAY}(${pool_delegation})${NC}"
                fi
              fi
              if [[ -z ${pay_addr} && -z ${pay_script_addr} ]]; then
                println "\n${FG_YELLOW}INFO${NC}: '${FG_LGRAY}${WALLET_PAY_ADDR_FILENAME}${NC}' missing and '${FG_LGRAY}${WALLET_PAY_VK_FILENAME}${NC}' to generate it!"
              fi
              [[ -z ${base_addr} ]]   && println "\n${FG_YELLOW}INFO${NC}: '${FG_LGRAY}${WALLET_BASE_ADDR_FILENAME}${NC}' missing and '${FG_LGRAY}${WALLET_PAY_VK_FILENAME}${NC}/${FG_LGRAY}${WALLET_STAKE_VK_FILENAME}${NC}' to generate it!"
              [[ -z ${reward_addr} ]] && println "\n${FG_YELLOW}INFO${NC}: '${FG_LGRAY}${WALLET_STAKE_ADDR_FILENAME}${NC}' missing and '${FG_LGRAY}${WALLET_STAKE_VK_FILENAME}${NC}' to generate it!"

              drep_script_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_SCRIPT_FILENAME}"
              if [[ ${CNTOOLS_MODE} != "OFFLINE" && ! -f "${drep_script_file}" ]] && versionCheck "9.0" "${PROT_VERSION}"; then
                println "DEBUG" "\nGovernance Vote Delegation Status"
                unset walletName
                if getWalletVoteDelegation ${wallet_name}; then
                  unset vote_delegation_hash
                  vote_delegation_type="${vote_delegation%-*}"
                  if [[ ${vote_delegation} = always* ]]; then
                    if [[ ${vote_delegation} = alwaysAbstain ]]; then
                      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Delegation" "Always abstain")"
                    else
                      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Delegation" "Always no confidence")"
                    fi
                  else
                    if [[ ${vote_delegation} = *-* ]]; then
                      vote_delegation_hash="${vote_delegation#*-}"
                      while IFS= read -r -d '' _wallet; do
                        getGovKeyInfo "$(basename ${_wallet})"
                        if [[ "${drep_hash}" = "${vote_delegation_hash}" ]]; then
                          walletName="$(basename ${_wallet})" && break
                        fi
                      done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
                    fi
                    getDRepIds ${vote_delegation_type} ${vote_delegation_hash}
                    println "$(printf "%-20s ${FG_DGRAY}: CIP-105 =>${NC} ${FG_LGRAY}%s${NC}" "Delegation" "${drep_id}")"
                    println "$(printf "%-20s ${FG_DGRAY}: CIP-129 =>${NC} ${FG_LGRAY}%s${NC}" "" "${drep_id_cip129}")"
                    if [[ -n ${walletName} ]]; then
                      println "$(printf "%-20s ${FG_DGRAY}: Wallet  =>${NC} ${FG_GREEN}%s${NC}" "" "${walletName}")"
                    fi
                    if [[ ${vote_delegation_type} = keyHash ]]; then
                      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "DRep Type" "Key")"
                    else
                      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "DRep Type" "MultiSig")"
                    fi
                    if getDRepStatus ${vote_delegation_type} ${vote_delegation_hash}; then
                      [[ $(getEpoch) -lt ${drep_expiry} ]] && expire_status="${FG_GREEN}active${NC}" || expire_status="${FG_RED}inactive${NC} (vote power does not count)"
                      println "$(printf "%-20s ${FG_DGRAY}:${NC} epoch ${FG_LBLUE}%s${NC} - %s" "DRep expiry" "${drep_expiry}" "${expire_status}")"
                      if [[ -n ${drep_anchor_url} ]]; then
                        println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "DRep anchor url" "${drep_anchor_url}")"
                        getDRepAnchor "${drep_anchor_url}" "${drep_anchor_hash}"
                        case $? in
                          0) println "$(printf "%-20s ${FG_DGRAY}:${NC}\n${FG_LGRAY}" "DRep anchor data")"
                            jq -er "${drep_anchor_file}" 2>/dev/null || cat "${drep_anchor_file}"
                            println DEBUG "${NC}"
                            ;;
                          1) println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC}" "DRep anchor data" "Invalid URL or currently not available")" ;;
                          2) println "$(printf "%-20s ${FG_DGRAY}:${NC}\n${FG_LGRAY}" "DRep anchor data")"
                            jq -er "${drep_anchor_file}" 2>/dev/null || cat "${drep_anchor_file}"
                            println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC}" "DRep anchor hash" "mismatch")"
                            println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "  registered" "${drep_anchor_hash}")"
                            println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "  actual" "${drep_anchor_real_hash}")"
                            ;;
                        esac
                      fi
                    else
                      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_RED}%s${NC}" "Status" "Unable to get DRep status, retired?")"
                    fi
                  fi
                  getDRepVotePower ${vote_delegation_type} ${vote_delegation_hash}
                  println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LBLUE}%s${NC} ADA (${FG_LBLUE}%s${NC} %%)" "Active Vote power" "$(formatLovelace ${vote_power:=0})" "${vote_power_pct:=0}")"
                else
                  if versionCheck "10.0" "${PROT_VERSION}"; then 
                    println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC} - %s" "Delegation" "undelegated" "please note that reward withdrawals will not work until wallet is vote delegated")"
                  else
                    println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC}" "Delegation" "undelegated")"
                  fi
                fi
              fi
              waitToProceed && continue
              ;; ###################################################################
            remove)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> REMOVE"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, unable to verify wallet balance"
              fi
              echo
              println DEBUG "Select wallet to remove"
              selectWallet "balance"
              case $? in
                1) waitToProceed; continue ;;
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
                waitToProceed && continue
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
                waitToProceed && continue
              fi
              getWalletBalance ${wallet_name}
              getWalletRewards ${wallet_name}
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
                [[ ${base_lovelace} -gt 0 ]] && println "Base Funds : ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"
                [[ ${pay_lovelace} -gt 0 ]] && println "Payment Funds : ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"
                [[ ${reward_lovelace} -gt 0 ]] && println "Rewards : ${FG_LBLUE}$(formatLovelace ${reward_lovelace})${NC} ADA"
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
              waitToProceed && continue
              ;; ###################################################################
            decrypt)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> DECRYPT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              println DEBUG "Select wallet to decrypt"
              selectWallet "encrypted"
              case $? in
                1) waitToProceed; continue ;;
                2) continue ;;
              esac
              filesUnlocked=0
              keysDecrypted=0
              echo
              println DEBUG "Removing write protection from all wallet files"
              while IFS= read -r -d '' file; do
                unlockFile "${file}"
                filesUnlocked=$((++filesUnlocked))
                println DEBUG "${file}"
              done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -print0)
              if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -gt 0 ]]; then
                echo
                println DEBUG "Decrypting GPG encrypted wallet files"
                echo
                if ! getPasswordCust; then # $password variable populated by getPasswordCust function
                  println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                  waitToProceed && continue
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
              waitToProceed && continue
              ;; ###################################################################
            encrypt)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> ENCRYPT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              println DEBUG "Select wallet to encrypt"
              selectWallet "encrypted"
              case $? in
                1) waitToProceed; continue ;;
                2) continue ;;
              esac
              filesLocked=0
              keysEncrypted=0
              if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -le 0 ]]; then
                echo
                println DEBUG "Encrypting sensitive wallet keys with GPG"
                echo
                if ! getPasswordCust confirm; then # $password variable populated by getPasswordCust function
                  println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                  waitToProceed && continue
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
                waitToProceed && continue
              fi
              echo
              println DEBUG "Write protecting all wallet keys with 400 permission and if enabled 'chattr +i'"
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
              waitToProceed && continue
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
						" ) Send     - send ADA and/or custom Assets from a local wallet"\
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
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              
              # source wallet
              println DEBUG "Select ${FG_YELLOW}source${NC} wallet"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              s_wallet="${wallet_name}"
              s_payment_vk_file="${payment_vk_file}"
              s_payment_sk_file="${payment_sk_file}"
              getWalletBalance ${s_wallet} true true true true
              if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                # Both payment and base address available with funds, let user choose what to use
                println DEBUG "Select source wallet address"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
                select_opt "[b] Base (default)" "[e] Payment" "[Esc] Cancel"
                case $? in
                  0) s_addr="${base_addr}" ;;
                  1) s_addr="${pay_addr}" ;;
                  2) continue ;;
                esac
                echo
              elif [[ ${pay_lovelace} -gt 0 ]]; then
                s_addr="${pay_addr}"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA\n" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
              elif [[ ${base_lovelace} -gt 0 ]]; then
                s_addr="${base_addr}"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA\n" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${s_wallet}${NC}"
                waitToProceed && continue
              fi

              # Destination
              d_wallet=""
              println DEBUG "Select ${FG_YELLOW}destination${NC} type"
              select_opt "[w] Wallet" "[a] Address" "[Esc] Cancel"
              case $? in
                0) selectWallet "cache"
                  case $? in
                    1) waitToProceed; continue ;;
                    2) continue ;;
                  esac
                  d_wallet="${wallet_name}"
                  getBaseAddress ${d_wallet}
                  getPayAddress ${d_wallet}
                  if [[ -n "${base_addr}" && "${base_addr}" != "${s_addr}" && -n "${pay_addr}" && "${pay_addr}" != "${s_addr}" ]]; then
                    # Both base and payment address available, let user choose what to use
                    select_opt "[b] Base (default)" "[e] Payment" "[Esc] Cancel"
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
                    waitToProceed && continue
                  else
                    println ERROR "\n${FG_RED}ERROR${NC}: no address found for wallet ${FG_GREEN}${d_wallet}${NC} :("
                    waitToProceed && continue
                  fi
                  ;;
                1) getAnswerAnyCust d_addr "Address" ;;
                2) continue ;;
              esac
              # Destination could be empty, if so without getting a valid address
              if [[ -z ${d_addr} ]]; then
                println ERROR "${FG_RED}ERROR${NC}: destination address field empty"
                waitToProceed && continue
              fi

              if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
                getBalance ${s_addr} # need to re-fetch balance if CLI due to possibly being overwritten by payment balance lookup
                unset index_prefix
              else
                index_prefix="${s_addr},"
              fi
              declare -gA assets_left=()
              declare -gA assets_to_send=()
              for asset in "${!assets[@]}"; do
                [[ -n ${index_prefix} && ${asset} != ${index_prefix}* ]] && continue
                assets_left[${asset#*,}]=${assets[${asset}]}
              done

              # Add additional assets to transaction?
              if [[ ${#assets_left[@]} -gt 1 ]]; then
                println DEBUG "Additional assets found on address, include in transaction?"
                select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                case $? in
                  0) : ;;
                  1) declare -A assets_on_addr=()
                    for asset in "${!assets_left[@]}"; do
                      [[ ${asset} = "lovelace" ]] && continue
                      IFS='.' read -ra asset_arr <<< "${asset}"
                      assets_on_addr["${asset} ($(hexToAscii ${asset_arr[1]}))"]=0 # only interested in the key
                    done
                    while true; do
                      select_opt "${!assets_on_addr[@]}" "[Esc] Cancel"
                      selection=$?
                      [[ ${selected_value} = "[Esc] Cancel" ]] && continue 2
                      IFS=' ' read -ra selection_arr <<< "${selected_value}"
                      println DEBUG "Available to send: ${FG_LBLUE}$(formatAsset ${assets_left[${selection_arr[0]}]})${NC}"
                      getAnswerAnyCust asset_amount "Amount (commas allowed as thousand separator)"
                      asset_amount="${asset_amount//,}"
                      [[ ${asset_amount} = "all" ]] && asset_amount=${assets_left[${selection_arr[0]}]}
                      if ! isNumber ${asset_amount}; then println ERROR "${FG_RED}ERROR${NC}: invalid number, non digit characters found!" && continue; fi
                      if [[ ${asset_amount} -gt ${assets_left[${selection_arr[0]}]} ]]; then
                        println ERROR "${FG_RED}ERROR${NC}: you cant send more assets than available on address!" && continue
                      elif [[ ${asset_amount} -eq ${assets_left[${selection_arr[0]}]} ]]; then
                        unset "assets_left[${selection_arr[0]}]"
                      else
                        assets_left[${selection_arr[0]}]=$(( assets_left[${selection_arr[0]}] - asset_amount ))
                      fi
                      assets_to_send[${selection_arr[0]}]=${asset_amount}
                      unset "assets_on_addr[${selected_value}]"
                      [[ ${#assets_on_addr[@]} -eq 0 ]] && break
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
              fi

              # Amount
              assets_tx_out_d=""
              for idx in "${!assets_to_send[@]}"; do
                [[ ${idx} = "lovelace" ]] && continue
                [[ ${assets_to_send[${idx}]} -gt 0 ]] && assets_tx_out_d+="+${assets_to_send[${idx}]} ${idx}"
              done
              getMinUTxO "${d_addr}+1${assets_tx_out_d}"
              println DEBUG "\nAmount to Send (in ADA)"
              println DEBUG " Valid entry:"
              println DEBUG "   ${FG_LGRAY}>${NC} Integer (e.g. 15) or Decimal (e.g. 956.1235), commas allowed as thousand separator"
              println DEBUG "   ${FG_LGRAY}>${NC} The string '${FG_YELLOW}all${NC}' sends all available funds in source wallet"
              println DEBUG " Asset Info:"
              println DEBUG "   ${FG_LGRAY}>${NC} If '${FG_YELLOW}all${NC}' is used and the wallet contain multiple assets,"
              println DEBUG "   ${FG_LGRAY}>${NC} you will be asked to transfer all assets (incl ADA) to the destination address"
              println DEBUG " Minimum Amount: ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA"
              getAnswerAnyCust amountADA "Amount (ADA)"
              amountADA="${amountADA//,}"
              echo
              if  [[ ${amountADA} != "all" ]]; then
                if ! amount_lovelace=$(ADAToLovelace "${amountADA}"); then waitToProceed && continue; fi
                [[ ${amount_lovelace} -gt ${assets[${index_prefix}lovelace]} ]] && println ERROR "${FG_RED}ERROR${NC}: not enough funds on address, ${FG_LBLUE}$(formatLovelace ${assets[${index_prefix}lovelace]})${NC} ADA available but trying to send ${FG_LBLUE}$(formatLovelace ${amount_lovelace})${NC} ADA" && waitToProceed && continue
                if [[ ${amount_lovelace} -lt ${assets[${index_prefix}lovelace]} ]]; then
                  println DEBUG "Fee payed by sender? [else amount sent is reduced]"
                  select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
                  case $? in
                    0) include_fee="no" ;;
                    1) include_fee="yes" ;;
                    2) continue ;;
                  esac
                else
                  include_fee="yes"
                fi
              else
                amount_lovelace=${assets[${index_prefix}lovelace]}
                println DEBUG "ADA to send set to total supply: ${FG_LBLUE}$(formatLovelace ${amount_lovelace})${NC}"
                include_fee="yes"
              fi

              if [[ ${amount_lovelace} -eq ${assets[${index_prefix}lovelace]} ]]; then
                if [[ ${#assets_left[@]} -gt 1 ]]; then
                  println DEBUG "\nAll ADA selected to be sent, automatically add all tokens?"
                  select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
                  case $? in
                    0) declare -gA assets_left=()
                       declare -gA assets_to_send=()
                       for asset in "${!assets[@]}"; do
                         [[ -n ${index_prefix} && ${asset} != ${index_prefix}* ]] && continue
                         assets_to_send[${asset#*,}]=${assets[${asset}]} # add all assets, e.g clone assets array to assets_to_send
                       done
                       ;;
                    1) println ERROR "${FG_RED}ERROR${NC}: Unable to send all ADA as there are additional assets left on address not selected to be sent" && waitToProceed && continue ;;
                    2) continue ;;
                  esac
                else
                  unset assets_left
                  assets_to_send[lovelace]=${amount_lovelace}
                fi
              else
                assets_left[lovelace]=$(( assets_left[lovelace] - amount_lovelace ))
                assets_to_send[lovelace]=${amount_lovelace}
              fi

              # Optional metadata/message
              println "\nAdd a message to the transaction?"
              select_opt "[n] No" "[y] Yes"
              case $? in
                0)  unset metafile ;;
                1)  metafile="${TMP_DIR}/metadata_$(date '+%Y%m%d%H%M%S').json"
                    DEFAULTEDITOR="$(command -v nano &>/dev/null && echo 'nano' || echo 'vi')"
                    println OFF "\nA maximum of 64 characters(bytes) is allowed per line."
                    println OFF "${FG_YELLOW}Please don't change default file path when saving.${NC}"
                    waitToProceed "press any key to open '${FG_LGRAY}${DEFAULTEDITOR}${NC}' text editor"
                    ${DEFAULTEDITOR} "${metafile}"
                    if [[ ! -f "${metafile}" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: file not found"
                      println ERROR "File: ${FG_LGRAY}${metafile}${NC}"
                      waitToProceed && continue
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
                      [[ -n ${error} ]] && println ERROR "${error}" && waitToProceed && continue
                      jq -c . <<< "${tx_msg}" > "${metafile}"
                      jq -r . "${metafile}" && echo
                      println LOG "Transaction message: ${tx_msg}"
                    fi
                    ;;
              esac

              if ! sendAssets; then
                waitToProceed && continue
              fi
              echo
              if ! verifyTx ${s_addr}; then waitToProceed && continue; fi
              getAddressBalance ${s_addr} true
              s_balance=${lovelace}
              getAddressBalance ${d_addr} true
              d_balance=${lovelace}
              getPayAddress ${s_wallet}
              [[ "${pay_addr}" = "${s_addr}" ]] && s_wallet_type=" (payment)" || s_wallet_type=""
              echo
              println "Transaction"
              println "  From          : ${FG_GREEN}${s_wallet}${NC}${s_wallet_type}"
              println "  Amount        : ${FG_LBLUE}$(formatLovelace ${amount_lovelace})${NC} ADA"
              for idx in "${!assets_to_send[@]}"; do
                [[ ${idx} = "lovelace" ]] && continue
                println "                  ${FG_LBLUE}$(formatAsset ${assets_to_send[${idx}]})${NC} ${FG_LGRAY}${idx}${NC}"
              done
              if [[ -n "${d_wallet}" ]]; then
                getPayAddress ${d_wallet}
                [[ "${pay_addr}" = "${d_addr}" ]] && d_wallet_type=" (payment)" || d_wallet_type=""
                println "  To            : ${FG_GREEN}${d_wallet}${NC}${d_wallet_type}"
              else
                println "  To            : ${FG_LGRAY}${d_addr}${NC}"
              fi
              println "  Fees          : ${FG_LBLUE}$(formatLovelace ${min_fee})${NC} ADA"
              println "  Balance"
              println "  - Source      : ${FG_LBLUE}$(formatLovelace ${s_balance})${NC} ADA"
              println "  - Destination : ${FG_LBLUE}$(formatLovelace ${d_balance})${NC} ADA"
              waitToProceed && continue
              ;; ###################################################################
            delegate)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> FUNDS >> DELEGATE"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "Select wallet to delegate"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "delegate"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "delegate"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              getWalletBalance ${wallet_name} true true false true
              if [[ ${base_lovelace} -gt 0 ]]; then
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Funds on address:"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "\n${FG_RED}ERROR${NC}: no base funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                waitToProceed && continue
              fi
              if ! isWalletRegistered ${wallet_name}; then
                if [[ ${op_mode} = "online" ]]; then
                  if ! registerStakeWallet ${wallet_name}; then waitToProceed && continue; fi
                  # re-fetch balance to get a fresh set of utxos
                  getWalletBalance ${wallet_name} true true false true
                else
                  println ERROR "\n${FG_YELLOW}The wallet is not a registered wallet on chain and CNTools run in hybrid mode${NC}"
                  println ERROR "Please first register the wallet using 'Wallet >> Register'"
                  waitToProceed && continue
                fi
              fi
              echo
              println DEBUG "Do you want to delegate to a local CNTools pool or specify the pool ID?"
              select_opt "[p] CNTools Pool" "[i] Pool ID" "[Esc] Cancel"
              case $? in
                0) selectPool "reg" "${POOL_COLDKEY_VK_FILENAME}"
                  case $? in
                    1) waitToProceed; continue ;;
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
              if ! delegate; then
                if [[ ${op_mode} = "online" ]]; then
                  echo && println ERROR "${FG_RED}ERROR${NC}: failure during delegation, removing newly created delegation certificate file"
                  rm -f "${pool_delegcert_file}"
                fi
                waitToProceed && continue
              fi
              echo
              if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
              getWalletBalance ${wallet_name} true true false
              echo
              println "Delegation successfully registered"
              println "Wallet : ${FG_GREEN}${wallet_name}${NC}"
              println "Pool   : ${FG_GREEN}${pool_name}${NC}"
              println "Amount : ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"
              waitToProceed && continue
              ;; ###################################################################
            withdrawrewards)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> FUNDS >> WITHDRAW REWARDS"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "Select wallet to withdraw funds from"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "reward"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "reward"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              echo
              getWalletBalance ${wallet_name} true true false true
              getWalletRewards ${wallet_name}
              if [[ ${reward_lovelace} -le 0 ]]; then
                println ERROR "Failed to locate any rewards associated with the chosen wallet, please try another one"
                waitToProceed && continue
              elif [[ ${base_lovelace} -eq 0 ]]; then
                println ERROR "${FG_YELLOW}WARN${NC}: No funds on base address, please send funds to base address of wallet to cover withdraw transaction fee"
                waitToProceed && continue
              fi
              println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Base Funds" "$(formatLovelace ${base_lovelace})")"
              println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Rewards" "$(formatLovelace ${reward_lovelace})")"
              if versionCheck "10.0" "${PROT_VERSION}" && ! getWalletVoteDelegation ${wallet_name}; then
                println ERROR "Reward withdrawal is blocked until wallet is vote delegated to a DRep or one of the predefined roles."
                waitToProceed && continue
              fi
              if ! withdrawRewards; then
                waitToProceed && continue
              fi
              echo
              if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
              getWalletBalance ${wallet_name} true true false
              echo
              println "Rewards successfully withdrawn"
              println "Base Funds (new balance) : ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"
              waitToProceed && continue
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
						"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Pool Operation\n"
          select_opt "[n] New" "[i] Import" "[r] Register" "[m] Modify" "[x] Retire" "[l] List" "[s] Show" "[o] Rotate" "[d] Decrypt" "[e] Encrypt" "[h] Home"
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
            10) break ;;
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
                waitToProceed && continue
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
                waitToProceed && continue
              fi
              println ACTION "${CCLI} ${NETWORK_ERA} node key-gen-KES --verification-key-file ${pool_hotkey_vk_file} --signing-key-file ${pool_hotkey_sk_file}"
              if ! stdout=$(${CCLI} ${NETWORK_ERA} node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}" 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during KES key creation!\n${stdout}"; waitToProceed && continue
              fi
              if [ -f "${POOL_FOLDER}-pregen/${pool_name}/${POOL_ID_FILENAME}" ]; then
                mv ${POOL_FOLDER}'-pregen/'${pool_name}/* ${POOL_FOLDER}/${pool_name}/
                rm -r ${POOL_FOLDER}'-pregen/'${pool_name}
              else
                println ACTION "${CCLI} ${NETWORK_ERA} node key-gen --cold-verification-key-file ${pool_coldkey_vk_file} --cold-signing-key-file ${pool_coldkey_sk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file}"
                if ! stdout=$(${CCLI} ${NETWORK_ERA} node key-gen --cold-verification-key-file "${pool_coldkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" 2>&1); then
                  println ERROR "\n${FG_RED}ERROR${NC}: failure during operational certificate counter file creation!\n${stdout}"; waitToProceed && continue
                fi
              fi
              println ACTION "${CCLI} ${NETWORK_ERA} node key-gen-VRF --verification-key-file ${pool_vrf_vk_file} --signing-key-file ${pool_vrf_sk_file}"
              if ! stdout=$(${CCLI} ${NETWORK_ERA} node key-gen-VRF --verification-key-file "${pool_vrf_vk_file}" --signing-key-file "${pool_vrf_sk_file}" 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during VRF key creation!\n${stdout}"; waitToProceed && continue
              fi
              chmod 600 "${POOL_FOLDER}/${pool_name}/"*
              getPoolID ${pool_name}
              echo
              println "Pool: ${FG_GREEN}${pool_name}${NC}"
              [[ -n ${pool_id} ]] && println "ID (hex)    : ${pool_id}"
              [[ -n ${pool_id_bech32} ]] && println "ID (bech32) : ${pool_id_bech32}"
              waitToProceed && continue
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
                waitToProceed && continue
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
                waitToProceed && continue
              fi

              println ACTION "${CCLI} ${NETWORK_ERA} node key-gen-KES --verification-key-file ${pool_hotkey_vk_file} --signing-key-file ${pool_hotkey_sk_file}"
              if ! stdout=$(${CCLI} ${NETWORK_ERA} node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}" 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during KES key creation!\n${stdout}"; waitToProceed && continue
              fi

              println ACTION "${CCLI} ${NETWORK_ERA} node key-gen-VRF --verification-key-file ${pool_vrf_vk_file} --signing-key-file ${pool_vrf_sk_file}"
              if ! stdout=$(${CCLI} ${NETWORK_ERA} node key-gen-VRF --verification-key-file "${pool_vrf_vk_file}" --signing-key-file "${pool_vrf_sk_file}" 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during VRF key creation!\n${stdout}"; waitToProceed && continue
              fi

              if ! unlockHWDevice "export cold pub keys"; then safeDel "${POOL_FOLDER}/${pool_name}"; continue; fi
              println ACTION "cardano-hw-cli node key-gen --path 1853H/1815H/0H/0H --hw-signing-file ${pool_coldkey_sk_file} --cold-verification-key-file ${pool_coldkey_kk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file}"
              if ! stdout=$(cardano-hw-cli node key-gen --path "1853H/1815H/0H/0H" --hw-signing-file "${pool_coldkey_sk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during HW key extraction!\n${stdout}"; waitToProceed && continue
              fi

              jq '.description = "Stake Pool Operator Hardware Verification Key"' "${pool_coldkey_vk_file}" > "${TMP_DIR}/$(basename "${pool_coldkey_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${pool_coldkey_vk_file}").tmp" "${pool_coldkey_vk_file}"

              chmod 600 "${POOL_FOLDER}/${pool_name}/"*
              sed -i 's/Shelley//g' "${pool_coldkey_vk_file}" # TEMP FIX FOR https://github.com/vacuumlabs/cardano-hw-cli/issues/139
              getPoolID ${pool_name} && touch "${POOL_FOLDER}/${pool_name}/.hwtype"
              echo
              println "Pool: ${FG_GREEN}${pool_name}${NC}"
              [[ -n ${pool_id} ]] && println "ID (hex)    : ${pool_id}"
              [[ -n ${pool_id_bech32} ]] && println "ID (bech32) : ${pool_id_bech32}"
              waitToProceed && continue
              ;; ##################################################################
            register|modify)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> ${SUBCOMMAND^^}"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo

              unset isHWpool
              println DEBUG "Select pool to register|modify"
              [[ ${SUBCOMMAND} = "register" ]] && pool_filter="non-reg" || pool_filter="reg"
              if [[ ${op_mode} = "online" ]]; then
                selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_VRF_VK_FILENAME}"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
                case $? in
                  0) isHWpool=Y ;;
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: signing keys missing from pool!" && waitToProceed && continue ;;
                esac
              else
                selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_VRF_VK_FILENAME}"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
                [[ $? -eq 0 ]] && isHWpool=Y
              fi
              echo
              pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
              println DEBUG "Pool Parameters"
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
              getAnswerAnyCust pledge_enter "Pledge (in ADA, default: $(formatLovelace "$(ADAToLovelace ${pledge_ada})")"
              pledge_enter="${pledge_enter//,}"
              if [[ -n "${pledge_enter}" ]]; then
                if ! ADAToLovelace "${pledge_enter}" >/dev/null; then
                  waitToProceed && continue
                fi
                pledge_lovelace=$(ADAToLovelace "${pledge_enter}")
                pledge_ada="${pledge_enter}"
              else
                pledge_lovelace=$(ADAToLovelace "${pledge_ada}")
              fi
              margin=7.5 # default margin in %
              [[ -f "${pool_config}" ]] && margin=$(jq -r '.margin //0' "${pool_config}")
              getAnswerAnyCust margin_enter "Margin (in %, default: ${margin})"
              if [[ -n "${margin_enter}" ]]; then
                if ! pctToFraction "${margin_enter}" >/dev/null; then
                  waitToProceed && continue
                fi
                margin_fraction=$(pctToFraction "${margin_enter}")
                margin="${margin_enter}"
              else
                margin_fraction=$(pctToFraction "${margin}")
              fi
              minPoolCost=$(formatLovelace ${MIN_POOL_COST} normal) # convert to ADA
              [[ -f ${pool_config} ]] && cost_ada=$(jq -r '.costADA //0' "${pool_config}") || cost_ada=${minPoolCost} # default cost
              [[ $(bc -l <<< "${cost_ada} < ${minPoolCost}") -eq 1 ]] && cost_ada=${minPoolCost} # raise old value to new minimum cost
              getAnswerAnyCust cost_enter "Cost (in ADA, minimum: ${minPoolCost}, default: ${cost_ada})"
              cost_enter="${cost_enter//,}"
              if [[ -n "${cost_enter}" ]]; then
                if ! ADAToLovelace "${cost_enter}" >/dev/null; then
                  waitToProceed && continue
                fi
                cost_lovelace=$(ADAToLovelace "${cost_enter}")
                cost_ada="${cost_enter}"
              else
                cost_lovelace=$(ADAToLovelace "${cost_ada}")
              fi
              if [[ $(bc -l <<< "${cost_ada} < ${minPoolCost}") -eq 1 ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: cost set lower than allowed"
                waitToProceed && continue
              fi
              println DEBUG "\nPool Metadata\n"
              pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta.json"
              if [[ ! -f "${pool_config}" ]] || ! meta_json_url=$(jq -er .json_url "${pool_config}"); then meta_json_url="https://foo.bat/poolmeta.json"; fi
              getAnswerAnyCust json_url_enter "Enter Pool's JSON URL to host metadata file - URL length should be less than 64 chars (default: ${meta_json_url})"
              [[ -n "${json_url_enter}" ]] && meta_json_url="${json_url_enter}"
              if [[ ! "${meta_json_url}" =~ https?://.* || ${#meta_json_url} -gt 64 ]]; then
                println ERROR "${FG_RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
                waitToProceed && continue
              fi
              metadata_done=false
              meta_tmp="${TMP_DIR}/url_poolmeta.json"
              if curl -sL -f -m ${CURL_TIMEOUT} -o "${meta_tmp}" ${meta_json_url} && jq -er . "${meta_tmp}" &>/dev/null; then
                [[ $(wc -c <"${meta_tmp}") -gt 512 ]] && println ERROR "${FG_RED}ERROR${NC}: file at specified URL contain more than allowed 512b of data!" && waitToProceed && continue
                echo && jq -r . "${meta_tmp}" && echo
                if ! jq -er .name "${meta_tmp}" &>/dev/null; then println ERROR "${FG_RED}ERROR${NC}: unable to get 'name' field from downloaded metadata file!" && waitToProceed && continue; fi
                if ! jq -er .ticker "${meta_tmp}" &>/dev/null; then println ERROR "${FG_RED}ERROR${NC}: unable to get 'ticker' field from downloaded metadata file!" && waitToProceed && continue; fi
                if ! jq -er .homepage "${meta_tmp}" &>/dev/null; then println ERROR "${FG_RED}ERROR${NC}: unable to get 'homepage' field from downloaded metadata file!" && waitToProceed && continue; fi
                if ! jq -er .description "${meta_tmp}" &>/dev/null; then println ERROR "${FG_RED}ERROR${NC}: unable to get 'description' field from downloaded metadata file!" && waitToProceed && continue; fi
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
                  waitToProceed && continue
                fi
                getAnswerAnyCust ticker_enter "Enter Pool's Ticker , should be between 3-5 characters (default: ${meta_ticker})"
                ticker_enter=${ticker_enter//[^[:alnum:]]/}
                [[ -n "${ticker_enter}" ]] && meta_ticker="${ticker_enter^^}"
                if [[ ${#meta_ticker} -lt 3 || ${#meta_ticker} -gt 5 ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: ticker must be between 3-5 characters"
                  waitToProceed && continue
                fi
                getAnswerAnyCust desc_enter "Enter Pool's Description (default: ${meta_description})"
                [[ -n "${desc_enter}" ]] && meta_description="${desc_enter}"
                if [[ ${#meta_description} -gt 255 ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: Description cannot exceed 255 characters"
                  waitToProceed && continue
                fi
                getAnswerAnyCust homepage_enter "Enter Pool's Homepage (default: ${meta_homepage})"
                [[ -n "${homepage_enter}" ]] && meta_homepage="${homepage_enter}"
                if [[ ! "${meta_homepage}" =~ https?://.* || ${#meta_homepage} -gt 64 ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
                  waitToProceed && continue
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
                      waitToProceed && continue
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
                  waitToProceed && continue
                else
                  cp -f "${new_pool_meta_file}" "${pool_meta_file}"
                fi
                println DEBUG "\n${FG_YELLOW}Please host file ${pool_meta_file} as-is at ${meta_json_url}${NC}"
                waitToProceed "Press any key to proceed with registration after metadata file is uploaded"
              fi
              relay_output=""
              relay_array=()
              println DEBUG "\nPool Relay Registration"
              if [[ -f "${pool_config}" && $(jq '.relays | length' "${pool_config}") -gt 0 ]]; then
                println DEBUG "\nPrevious relay configuration:\n"
                jq -r '["TYPE","ADDRESS","PORT"], (.relays[] | [.type //"-",.address //"-",.port //"-"]) | @tsv' "${pool_config}" | column -t
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
                        if ! isValidIPv4 "${relay_ip_enter}" && ! isValidIPv6 "${relay_ip_enter}" && ! isValidHostnameOrDomain "${relay_ip_enter}"; then
                            println ERROR "${FG_RED}ERROR${NC}: Invalid IPv4/v6 address format or hostname/domain name format!"
                        else
                          getAnswerAnyCust relay_port_enter "Enter relays's port"
                          if [[ -n "${relay_port_enter}" ]]; then
                            if ! isNumber ${relay_port_enter} || [[ ${relay_port_enter} -lt 1 || ${relay_port_enter} -gt 65535 ]]; then
                              println ERROR "${FG_RED}ERROR${NC}: invalid port number!"
                            elif isValidIPv4 "${relay_ip_enter}" || isValidHostnameOrDomain "${relay_ip_enter}"; then
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

                println DEBUG "Previous Owner(s)/Reward wallets"
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
                              waitToProceed "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N' && break
                            else hw_owner_wallets='Y'; fi ;;
                        2) if [[ ${op_mode} = "online" ]]; then
                              println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted for wallet ${FG_GREEN}${wallet_name}${NC}, please decrypt before use!"
                              waitToProceed && continue 2
                            fi ;;
                        3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                            waitToProceed "Did you mean to run in Hybrid mode?  press any key to return home!" && continue 2 ;;
                        4) if [[ ${wallet_name} != "${owner_wallets[0]}" && ! -f "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ]]; then # ignore if payment vkey is missing for multi-owner, only stake vkey important
                              println ERROR "${FG_RED}ERROR${NC}: stake verification key missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                              waitToProceed "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N' && break
                            fi ;;
                      esac
                      if [[ ${wallet_name} = "${owner_wallets[0]}" ]] && ! isWalletRegistered ${wallet_name}; then # make sure at least main owner is registered
                        if [[ ${op_mode} = "hybrid" ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not a registered wallet on chain and CNTools run in hybrid mode"
                          println ERROR "Please first register main owner wallet to use in pool registration using 'Wallet >> Register'"
                          waitToProceed && continue 2
                        fi
                        getWalletBalance ${wallet_name} true true false true
                        if [[ ${base_lovelace} -eq 0 ]]; then
                          println ERROR "${FG_RED}ERROR${NC}: no funds available on base address for wallet ${FG_GREEN}${wallet_name}${NC}, needed to pay for registration fee"
                          waitToProceed && continue 2
                        fi
                        println DEBUG "Wallet Registration Transaction"
                        if ! registerStakeWallet ${wallet_name}; then waitToProceed && continue 2; fi
                      fi
                    done

                    if [[ ${reuse_wallets} = 'Y' ]]; then # re-check reuse_wallets in case flow was broken
                      getWalletType ${reward_wallet}
                      case $? in
                        0) hw_reward_wallet='Y' ;;
                        4) if [[ ! -f "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ]]; then # ignore if payment vkey is missing for reward wallet, only stake vkey important
                              println ERROR "${FG_RED}ERROR${NC}: stake verification key missing from reward wallet ${FG_GREEN}${wallet_name}${NC}!"
                              waitToProceed "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N'
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
                println DEBUG "Select main ${FG_YELLOW}owner/pledge${NC} wallet (normal CLI wallet)"
                if [[ ${op_mode} = "online" ]]; then
                  if ! selectWallet "delegate"; then # ${wallet_name} populated by selectWallet function
                    [[ "${dir_name}" != "[Esc] Cancel" ]] && waitToProceed; continue
                  fi
                  getWalletType ${wallet_name}
                  case $? in
                    0) println ERROR "${FG_RED}ERROR${NC}: main pool owner can NOT be a hardware wallet!"
                      println ERROR "Use a CLI wallet as owner with enough funds to pay for pool deposit and registration transaction fee"
                      println ERROR "Add the hardware wallet as an additional multi-owner to the pool later in the pool registration wizard"
                      waitToProceed && continue ;;
                    2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                    3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                    5) println ERROR "${FG_RED}ERROR${NC}: MultiSig wallet pool owners not supported!"
                      println ERROR "Use a CLI wallet as owner with enough funds to pay for pool deposit and registration transaction fee"
                      waitToProceed && continue ;;
                  esac
                else
                  selectWallet "delegate"
                  case $? in
                    1) waitToProceed; continue ;;
                    2) continue ;;
                  esac
                  getWalletType ${wallet_name}
                fi
                if ! isWalletRegistered ${wallet_name}; then
                  if [[ ${op_mode} = "hybrid" ]]; then
                    println ERROR "\n${FG_RED}ERROR${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not a registered wallet on chain and CNTools run in hybrid mode"
                    println ERROR "Please first register the main CLI wallet to use in pool registration using 'Wallet >> Register'"
                    waitToProceed && continue
                  fi
                  getWalletBalance ${wallet_name} true true false true
                  if [[ ${base_lovelace} -eq 0 ]]; then
                    println ERROR "${FG_RED}ERROR${NC}: no funds available on base address for wallet ${FG_GREEN}${wallet_name}${NC}, needed to pay for registration fee"
                    waitToProceed && continue
                  fi
                  println DEBUG "Wallet Registration Transaction"
                  if ! registerStakeWallet ${wallet_name}; then waitToProceed && continue; fi
                fi
                owner_wallets+=( "${wallet_name}" )
                println DEBUG "Owner #1 : ${FG_GREEN}${wallet_name}${NC} added!"
              fi

              if [[ ${reuse_wallets} = 'N' ]]; then
                println DEBUG "\nRegister a multi-owner pool (you need to have stake.vkey of any additional owner in a seperate wallet folder under $CNODE_HOME/priv/wallet)?"
                while true; do
                  select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                  case $? in
                    0) break ;;
                    1) if selectWallet "delegate" "${owner_wallets[@]}"; then # ${wallet_name} populated by selectWallet function
                        getWalletType ${wallet_name}
                        case $? in
                          0) hw_owner_wallets='Y' ;;
                          2) if [[ ${op_mode} = "online" ]]; then
                              println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted for wallet ${FG_GREEN}${wallet_name}${NC}, please decrypt before use!"
                              waitToProceed && continue 2
                            fi ;;
                          3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                            waitToProceed "Did you mean to run in Hybrid mode?  press any key to return home!" && continue 2 ;;
                          4) if [[ ! -f "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ]]; then # ignore if payment vkey is missing
                              println ERROR "${FG_RED}ERROR${NC}: stake verification key missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                              println DEBUG "Add another owner?" && continue
                            fi ;;
                          5) println ERROR "${FG_RED}ERROR${NC}: MultiSig wallet pool owner not supported!"
                            waitToProceed && println DEBUG "Add more owners?" && continue ;;
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
                  1) if ! selectWallet "none" "${owner_wallets[0]}"; then # ${wallet_name} populated by selectWallet function
                      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitToProceed; continue
                    fi
                    reward_wallet="${wallet_name}"
                    getWalletType ${reward_wallet}
                    case $? in
                      0) hw_reward_wallet='Y' ;;
                      4) if [[ ! -f "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ]]; then # ignore if payment vkey is missing
                            println ERROR "${FG_RED}ERROR${NC}: stake verification key missing from wallet ${FG_GREEN}${wallet_name}${NC}!" && waitToProceed && continue
                          fi ;;
                    esac
                    ;;
                  2) continue ;;
                  5) println ERROR "${FG_RED}ERROR${NC}: MultiSig wallet as rewards wallet not supported!" && waitToProceed && continue ;;
                esac
              fi

              getWalletBalance ${owner_wallets[0]} true true false true
              if [[ ${base_lovelace} -eq 0 ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available on owner wallet base address ${FG_GREEN}${owner_wallets[0]}${NC}"
                waitToProceed && continue
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
                        if ! stdout=$(cardano-hw-cli node issue-op-cert \
                          --kes-verification-key-file "${pool_hotkey_vk_file}" \
                          --hw-signing-file "${pool_coldkey_sk_file}" \
                          --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" \
                          --kes-period "${current_kes_period}" \
                          --out-file "${pool_opcert_file}" 2>&1); then
                          println ERROR "\n${FG_RED}ERROR${NC}: failure during HW operational certificate creation!\n${stdout}"
                          return 1
                        fi
                    else
                      println ACTION "${CCLI} ${NETWORK_ERA} node issue-op-cert --kes-verification-key-file ${pool_hotkey_vk_file} --cold-signing-key-file ${pool_coldkey_sk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file} --kes-period ${current_kes_period} --out-file ${pool_opcert_file}"
                      if ! stdout=$(${CCLI} ${NETWORK_ERA} node issue-op-cert --kes-verification-key-file "${pool_hotkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" --kes-period "${current_kes_period}" --out-file "${pool_opcert_file}" 2>&1); then
                        println ERROR "\n${FG_RED}ERROR${NC}: failure during operational certificate creation!\n${stdout}"; waitToProceed && continue
                      fi
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
                  waitToProceed "press any key to continue"
                fi
              fi

              println LOG "creating registration certificate"
              println ACTION "${CCLI} ${NETWORK_ERA} stake-pool registration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --vrf-verification-key-file ${pool_vrf_vk_file} --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file ${reward_stake_vk_file} --pool-owner-stake-verification-key-file ${owner_stake_vk_file} ${multi_owner_output} --metadata-url ${meta_json_url} --metadata-hash \$\(${CCLI} ${NETWORK_ERA} stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} \) ${relay_output} ${NETWORK_IDENTIFIER} --out-file ${pool_regcert_file}"
              if ! stdout=$(${CCLI} ${NETWORK_ERA} stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${reward_stake_vk_file}" --pool-owner-stake-verification-key-file "${owner_stake_vk_file}" ${multi_owner_output} --metadata-url "${meta_json_url}" --metadata-hash "$(${CCLI} ${NETWORK_ERA} stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} )" ${relay_output} ${NETWORK_IDENTIFIER} --out-file "${pool_regcert_file}" 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during stake pool registration certificate creation!\n${stdout}"; waitToProceed && continue
              fi

              delegate_owner_wallet='N'
              if [[ ${SUBCOMMAND} = "register" ]]; then
                if [[ ${hw_owner_wallets} = 'Y' || ${hw_reward_wallet} = 'Y' || ${isHWpool} = 'Y' ]]; then
                  println DEBUG "\n${FG_BLUE}INFO${NC}: hardware wallet included as reward or multi-owner or hardware pool, automatic owner/reward wallet delegation disabled"
                  println DEBUG "${FG_BLUE}INFO${NC}: ${FG_YELLOW}please manually delegate all wallets to the pool!!!${NC}"
                  waitToProceed "press any key to continue"
                else
                  println LOG "creating delegation certificate for main owner wallet"
                  println ACTION "${CCLI} ${NETWORK_ERA} stake-address stake-delegation-certificate --stake-verification-key-file ${owner_stake_vk_file} --cold-verification-key-file ${pool_coldkey_vk_file} --out-file ${owner_delegation_cert_file}"
                  if ! stdout=$(${CCLI} ${NETWORK_ERA} stake-address stake-delegation-certificate --stake-verification-key-file "${owner_stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${owner_delegation_cert_file}" 2>&1); then
                    println ERROR "\n${FG_RED}ERROR${NC}: failure during stake delegation certificate creation!\n${stdout}"; waitToProceed && continue
                  fi
                  delegate_owner_wallet='Y'
                  if [[ "${owner_wallets[0]}" != "${reward_wallet}" ]]; then
                    println DEBUG "\n${FG_BLUE}INFO${NC}: reward wallet not the same as owner, automatic reward wallet delegation disabled"
                    println DEBUG "${FG_BLUE}INFO${NC}: ${FG_YELLOW}please manually delegate reward wallet to the pool!!!${NC}"
                    waitToProceed "press any key to continue"
                  fi
                fi
              fi

              if [[ ${SUBCOMMAND} = "register" ]]; then
                println DEBUG "\nPool Registration Transaction"
                registerPool
                rc=$?
              else
                println DEBUG "\nPool Update Transaction"
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
                [[ $rc -eq 1 ]] && waitToProceed && continue
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
                if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
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
              println "Pledge        : ${FG_LBLUE}$(formatLovelace "$(ADAToLovelace ${pledge_ada})")${NC} ADA"
              println "Margin        : ${FG_LBLUE}${margin}${NC} %"
              println "Cost          : ${FG_LBLUE}$(formatLovelace ${cost_lovelace})${NC} ADA"
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
                if [[ -n ${KOIOS_API} ]]; then
                  addr_list=()
                  reward_addr_list=()
                  for wallet_name in "${owner_wallets[@]}"; do
                    getBaseAddress ${wallet_name} && addr_list+=(${base_addr})
                    getRewardAddress ${wallet_name} && reward_addr_list+=(${reward_addr})
                  done
                  [[ ${#addr_list[@]} -gt 0 ]] && getBalanceKoios false
                  [[ ${#reward_addr_list[@]} -gt 0 ]] && getRewardInfoKoios
                  for key in "${!assets[@]}"; do
                    [[ ${key} = *lovelace ]] && total_pledge=$(( total_pledge + assets[${key}] ))
                  done
                  for value in "${rewards_available[@]}"; do
                    [[ ${value} -gt 0 ]] && total_pledge=$(( total_pledge + value ))
                  done
                else
                  for wallet_name in "${owner_wallets[@]}"; do
                    getBaseAddress ${wallet_name}
                    getBalance ${base_addr}
                    total_pledge=$(( total_pledge + assets[lovelace] ))
                    getWalletRewards ${wallet_name}
                    [[ ${reward_lovelace} -gt 0 ]] && total_pledge=$(( total_pledge + reward_lovelace ))
                  done
                fi
                println DEBUG "${FG_BLUE}INFO${NC}: Total balance in ${FG_LBLUE}${#owner_wallets[@]}${NC} owner/pledge wallet(s) are: ${FG_LBLUE}$(formatLovelace ${total_pledge})${NC} ADA"
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
              waitToProceed && continue
              ;; ###################################################################
            retire)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> RETIRE"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available to pay for pool de-registration!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "Select pool to retire"
              if [[ ${op_mode} = "online" ]]; then
                selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: signing keys missing from pool!" && waitToProceed && continue ;;
                esac
              else
                selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
              fi
              echo
              epoch=$(getEpoch)
              println DEBUG "Current epoch: ${FG_LBLUE}${epoch}${NC}"
              epoch_start=$((epoch + 1))
              epoch_end=$((epoch + POOL_RETIRE_MAX_EPOCH))
              println DEBUG "earliest epoch to retire pool is ${FG_LBLUE}${epoch_start}${NC} and latest ${FG_LBLUE}${epoch_end}${NC}"
              echo
              getAnswerAnyCust epoch_enter "Enter epoch in which to retire pool (blank for ${epoch_start})"
              [[ -z "${epoch_enter}" ]] && epoch_enter=${epoch_start}
              echo
              if [[ ${epoch_enter} -lt ${epoch_start} || ${epoch_enter} -gt ${epoch_end} ]]; then
                println ERROR "${FG_RED}ERROR${NC}: epoch invalid, valid range: ${epoch_start}-${epoch_end}"
                waitToProceed && continue
              fi
              println DEBUG "Select wallet for pool de-registration transaction fee"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for pool de-registration transaction fee!" && waitToProceed && continue ;;
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for pool de-registration transaction fee!" && waitToProceed && continue ;;
                esac
              fi
              getWalletBalance ${wallet_name} true true true true
              if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                # Both payment and base address available with funds, let user choose what to use
                println DEBUG "\nSelect wallet address to use"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
                select_opt "[b] Base (default)" "[e] Payment" "[Esc] Cancel"
                case $? in
                  0) addr="${base_addr}"; lovelace=${base_lovelace} ;;
                  1) addr="${pay_addr}";  lovelace=${pay_lovelace} ;;
                  2) continue ;;
                esac
              elif [[ ${pay_lovelace} -gt 0 ]]; then
                addr="${pay_addr}"
                lovelace=${pay_lovelace}
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "\n$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
              elif [[ ${base_lovelace} -gt 0 ]]; then
                addr="${base_addr}"
                lovelace=${base_lovelace}
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "\n$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                waitToProceed && continue
              fi
              pool_deregcert_file="${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}"
              pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"
              println LOG "creating de-registration cert"
              println ACTION "${CCLI} ${NETWORK_ERA} stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file}"
              if ! stdout=$(${CCLI} ${NETWORK_ERA} stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file} 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during stake pool deregistration certificate creation!\n${stdout}"; waitToProceed && continue
              fi
              echo
              if ! deRegisterPool; then
                waitToProceed && continue
              fi
              [[ -f "${pool_regcert_file}" ]] && rm -f ${pool_regcert_file} # delete registration cert
              echo
              if ! verifyTx ${addr}; then waitToProceed && continue; fi
              echo
              println "Pool ${FG_GREEN}${pool_name}${NC} set to be retired in epoch ${FG_LBLUE}${epoch_enter}${NC}"
              println "Pool deposit will be returned to owner reward address after its retired"
              waitToProceed && continue
              ;; ###################################################################
            list)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> LIST"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              current_epoch=$(getEpoch)
              while IFS= read -r -d '' pool; do
                echo
                pool_name="$(basename ${pool})"
                getPoolID "${pool_name}"
                pool_regcert_file="${pool}/${POOL_REGCERT_FILENAME}"
                isPoolRegistered "${pool_name}"
                case $? in
                  0) println "ERROR" "${FG_RED}KOIOS_API ERROR${NC}: ${error_msg}" && waitToProceed && continue ;;
                  1) pool_registered="${FG_RED}NO${NC}" ;;
                  2) pool_registered="${FG_GREEN}YES${NC}" ;;
                  3) if [[ ${current_epoch} -lt ${p_retiring_epoch} ]]; then
                       pool_registered="${FG_YELLOW}YES${NC} - Retiring in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
                     else
                       pool_registered="${FG_RED}NO${NC} - Retired in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
                     fi ;;
                  4) pool_registered="${FG_RED}NO${NC} - Retired in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}" ;;
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

                if [[ ${pool_registered} = *YES* ]]; then
                  unset pool_kes_start
                  unset remaining_kes_periods
                  [[ -f "${pool}/${POOL_CURRENT_KES_START}" ]] && pool_kes_start="$(cat "${pool}/${POOL_CURRENT_KES_START}")"

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
              done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
              echo
              waitToProceed && continue
              ;; ###################################################################
            show)
              clear
              [[ ${CNTOOLS_MODE} != "OFFLINE" ]] && getPriceInfo
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> SHOW"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, locally saved info shown!"
              fi
              tput sc
              selectPool "all" "${POOL_ID_FILENAME}"
              case $? in
                1) waitToProceed; continue ;;
                2) continue ;;
              esac
              current_epoch=$(getEpoch)
              getPoolID ${pool_name}
              tput rc && tput ed
              if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
                tput sc && println DEBUG "Querying pool parameters from node, can take a while...\n"
                println ACTION "${CCLI} ${NETWORK_ERA} query pool-params --stake-pool-id ${pool_id_bech32} ${NETWORK_IDENTIFIER}"
                if ! pool_params=$(${CCLI} ${NETWORK_ERA} query pool-params --stake-pool-id ${pool_id_bech32} ${NETWORK_IDENTIFIER} 2>&1); then
                  tput rc && tput ed
                  println ERROR "${FG_RED}ERROR${NC}: pool-params query failed: ${pool_params}"
                  waitToProceed && continue
                fi
                tput rc && tput ed
              fi
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                pool_registered="${FG_LGRAY}status unavailable in offline mode${NC}"
              elif [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
                ledger_pParams=$(jq -r '.[].poolParams // empty' <<< ${pool_params})
                ledger_fPParams=$(jq -r '.[].futurePoolParams // empty' <<< ${pool_params})
                ledger_retiring=$(jq -r '.[].retiring // empty' <<< ${pool_params})
                [[ -z ${ledger_retiring} ]] && p_retiring_epoch=0 || p_retiring_epoch=${ledger_retiring}
                [[ -z "${ledger_fPParams}" ]] && ledger_fPParams="${ledger_pParams}"
                [[ -n "${ledger_pParams}" ]] && pool_registered="${FG_GREEN}YES${NC}" || pool_registered="${FG_RED}NO${NC}"
                if [[ ${p_retiring_epoch} -gt 0 ]]; then
                  if [[ ${current_epoch} -lt ${p_retiring_epoch} ]]; then
                    pool_registered="${FG_YELLOW}YES${NC} - Retiring in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
                  else
                    pool_registered="${FG_RED}NO${NC} - Retired in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
                  fi
                fi
              else
                println OFF "\n${FG_YELLOW}> Querying Koios API for pool information (some data can have a small delay)${NC}"
                isPoolRegistered ${pool_name} # variables set in isPoolRegistered [pool_info, error_msg, p_<metric>]
                case $? in
                  0) println "ERROR" "\n${FG_RED}KOIOS_API ERROR${NC}: ${error_msg}" && waitToProceed && continue ;;
                  1) pool_registered="${FG_RED}NO${NC}" ;;
                  2) pool_registered="${FG_GREEN}YES${NC}" ;;
                  3) if [[ ${current_epoch} -lt ${p_retiring_epoch} ]]; then
                       pool_registered="${FG_YELLOW}YES${NC} - Retiring in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
                     else
                       pool_registered="${FG_RED}NO${NC} - Retired in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
                     fi ;;
                  4) pool_registered="${FG_RED}NO${NC} - Retired in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}" ;;
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
                  println "ACTION" "${CCLI} ${NETWORK_ERA} stake-pool metadata-hash --pool-metadata-file ${pool_meta_file}"
                  meta_hash="$( ${CCLI} ${NETWORK_ERA} stake-pool metadata-hash --pool-metadata-file "${pool_meta_file}" )"
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
                  println ACTION "${CCLI} ${NETWORK_ERA} stake-pool metadata-hash --pool-metadata-file ${TMP_DIR}/url_poolmeta.json"
                  if ! meta_hash_url=$(${CCLI} ${NETWORK_ERA} stake-pool metadata-hash --pool-metadata-file "${TMP_DIR}/url_poolmeta.json" 2>&1); then
                    println ERROR "\n${FG_RED}ERROR${NC}: failure during metadata hash creation!\n${meta_hash_url}"; waitToProceed && continue
                  fi
                  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" "Hash URL" "${meta_hash_url}")"
                  if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
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
                println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA" "Pledge" "$(formatLovelace "$(ADAToLovelace ${conf_pledge})")")"
                println "$(printf "%-21s : ${FG_LBLUE}%s${NC} %%" "Margin" "${conf_margin}")"
                println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA" "Cost" "$(formatLovelace "$(ADAToLovelace ${conf_cost})")")"
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
                if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
                  pParams_pledge=$(jq -r '.pledge //0' <<< "${ledger_pParams}")
                  fPParams_pledge=$(jq -r '.pledge //0' <<< "${ledger_fPParams}")
                else
                  fPParams_pledge=${p_pledge}
                  pParams_pledge=${fPParams_pledge}
                fi
                if [[ ${pParams_pledge} -eq ${fPParams_pledge} ]]; then
                  getPriceString ${pParams_pledge}
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA${price_str}" "Pledge" "$(formatLovelace "${pParams_pledge}")")"
                else
                  getPriceString ${fPParams_pledge}
                  println "$(printf "%-15s (${FG_YELLOW}%s${NC}) : ${FG_LBLUE}%s${NC} ADA${price_str}" "Pledge" "new" "$(formatLovelace "${fPParams_pledge}")" )"
                fi
                [[ -n ${KOIOS_API} ]] && getPriceString ${p_live_pledge} && println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA${price_str}" "Live Pledge" "$(formatLovelace "${p_live_pledge}")")"
                
                # get margin
                if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
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
                if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
                  pParams_cost=$(jq -r '.cost //0' <<< "${ledger_pParams}")
                  fPParams_cost=$(jq -r '.cost //0' <<< "${ledger_fPParams}")
                else
                  fPParams_cost=${p_fixed_cost}
                  pParams_cost=${fPParams_cost}
                fi
                if [[ ${pParams_cost} -eq ${fPParams_cost} ]]; then
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA" "Cost" "$(formatLovelace "${pParams_cost}")")"
                else
                  println "$(printf "%-15s (${FG_YELLOW}%s${NC}) : ${FG_LBLUE}%s${NC} ADA" "Cost" "new" "$(formatLovelace "${fPParams_cost}")" )"
                fi
                
                # get relays
                if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
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
                    if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
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
                if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
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
                if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
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
                
                if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
                  # get stake distribution
                  println "ACTION" "LC_NUMERIC=C printf %.10f \$(${CCLI} ${NETWORK_ERA} query stake-distribution ${NETWORK_IDENTIFIER} | grep ${pool_id_bech32} | tr -s ' ' | cut -d ' ' -f 2))"
                  stake_pct=$(fractionToPCT "$(LC_NUMERIC=C printf "%.10f" "$(${CCLI} ${NETWORK_ERA} query stake-distribution ${NETWORK_IDENTIFIER} | grep "${pool_id_bech32}" | tr -s ' ' | cut -d ' ' -f 2)")")
                  if validateDecimalNbr ${stake_pct}; then
                    println "$(printf "%-21s : ${FG_LBLUE}%s${NC} %%" "Stake distribution" "${stake_pct}")"
                  fi
                else
                  # get active/live stake/block info
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA" "Active Stake" "$(formatLovelace "${p_active_stake}")")"
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC}" "Lifetime Blocks" "${p_block_count}")"
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA" "Live Stake" "$(formatLovelace "${p_live_stake}")")"
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} (incl owners)" "Delegators" "${p_live_delegators}")"
                  println "$(printf "%-21s : ${FG_LBLUE}%s${NC} %%" "Saturation" "${p_live_saturation}")"
                fi

                if [[ -n ${KOIOS_API} ]]; then
                  [[ ${p_op_cert_counter} != null ]] && kes_counter_str="${FG_LBLUE}${p_op_cert_counter}${FG_LGRAY} - use counter ${FG_LBLUE}$((p_op_cert_counter+1))${FG_LGRAY} for rotation in offline mode.${NC}" || kes_counter_str="${FG_LGRAY}No blocks minted so far with active operational certificate. Use counter ${FG_LBLUE}0${FG_LGRAY} for rotation in offline mode.${NC}"
                  println "$(printf "%-21s : %s" "KES counter" "${kes_counter_str}")"
                elif [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
                  pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"
                  println ACTION "${CCLI} ${NETWORK_ERA} query kes-period-info --op-cert-file ${pool_opcert_file} ${NETWORK_IDENTIFIER}"
                  if ! kes_period_info=$(${CCLI} ${NETWORK_ERA} query kes-period-info --op-cert-file "${pool_opcert_file}" ${NETWORK_IDENTIFIER}); then
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
                fi

                unset pool_kes_start
                [[ -f "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}" ]] && pool_kes_start="$(cat "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}")"
                unset remaining_kes_periods

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
              waitToProceed && continue
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
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              println DEBUG "Select pool to rotate KES keys on"
              selectPool "all" "${POOL_COLDKEY_VK_FILENAME}"
              case $? in
                1) waitToProceed; continue ;;
                2) continue ;;
              esac
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                getAnswerAnyCust new_counter "Enter new counter number"
                if ! isNumber ${new_counter}; then
                  println ERROR "\n${FG_RED}ERROR${NC}: not a number"
                  waitToProceed && continue
                fi
                if ! rotatePoolKeys ${new_counter}; then
                  waitToProceed && continue
                fi
              else
                if ! rotatePoolKeys; then
                  waitToProceed && continue
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
              waitToProceed && continue
              ;; ###################################################################
            decrypt)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> DECRYPT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              println DEBUG "Select pool to decrypt"
              selectPool "encrypted"
              case $? in
                1) waitToProceed; continue ;;
                2) continue ;;
              esac
              filesUnlocked=0
              keysDecrypted=0
              echo
              println DEBUG "Removing write protection from all pool files"
              while IFS= read -r -d '' file; do
                unlockFile "${file}"
                filesUnlocked=$((++filesUnlocked))
                println DEBUG "${file}"
              done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)
              if [[ $(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -gt 0 ]]; then
                echo
                println "Decrypting GPG encrypted pool files"
                if ! getPasswordCust; then # $password variable populated by getPasswordCust function
                  println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                  waitToProceed && continue
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
              waitToProceed && continue
              ;; ###################################################################
            encrypt)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> ENCRYPT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              println DEBUG "Select pool to encrypt"
              selectPool "encrypted"
              case $? in
                1) waitToProceed; continue ;;
                2) continue ;;
              esac
              filesLocked=0
              keysEncrypted=0
              if [[ $(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -le 0 ]]; then
                echo
                println DEBUG "Encrypting sensitive pool keys with GPG"
                if ! getPasswordCust confirm; then # $password variable populated by getPasswordCust function
                  println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                  waitToProceed && continue
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
                waitToProceed && continue
              fi
              echo
              println DEBUG "Write protecting all pool files with 400 permission and if enabled 'chattr +i'"
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
              waitToProceed && continue
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
              fileDialog "Enter path to transaction file to sign" "${TMP_DIR}/" && echo
              offline_tx=${file}
              [[ -z "${offline_tx}" ]] && continue
              if [[ ! -f "${offline_tx}" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: file not found: ${offline_tx}"
                waitToProceed && continue
              elif ! offlineJSON=$(jq -erc . "${offline_tx}"); then
                println ERROR "${FG_RED}ERROR${NC}: invalid JSON file: ${offline_tx}"
                waitToProceed && continue
              fi
              if ! otx_type="$(jq -er '.type' <<< ${offlineJSON})"; then println ERROR "${FG_RED}ERROR${NC}: field 'type' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_date_created="$(jq -er '."date-created"' <<< ${offlineJSON})"; then println ERROR "${FG_RED}ERROR${NC}: field 'date-created' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_date_expire="$(jq -er '."date-expire"' <<< ${offlineJSON})"; then println ERROR "${FG_RED}ERROR${NC}: field 'date-expire' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_txFee=$(jq -er '.txFee' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'txFee' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_txBody=$(jq -er '.txBody' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'txBody' not found in: ${offline_tx}" && waitToProceed && continue; fi
              echo -e "${otx_txBody}" > "${TMP_DIR}"/tx.raw
              println DEBUG "Transaction type : ${FG_GREEN}${otx_type}${NC}"
              if wallet_name=$(jq -er '."wallet-name"' <<< ${offlineJSON}); then 
                println DEBUG "Transaction fee  : ${FG_LBLUE}$(formatLovelace ${otx_txFee})${NC} ADA, payed by ${FG_GREEN}${wallet_name}${NC}"
                [[ $(cat "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}" 2>/dev/null) = "${addr}" ]] && wallet_source="payment" || wallet_source="base"
              else
                println DEBUG "Transaction fee  : ${FG_LBLUE}$(formatLovelace ${otx_txFee})${NC} ADA"
              fi
              println DEBUG "Created          : ${FG_LGRAY}$(date '+%F %T %Z' --date="${otx_date_created}")${NC}"
              [[ $(date '+%s' --date="${otx_date_expire}") -lt $(date '+%s') ]] && expire_color="${FG_RED}" || expire_color="${FG_LGRAY}"
              println DEBUG "Expire           : ${expire_color}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}"
              echo
              tx_witness_files=()
              case "${otx_type}" in
                "Pool Registration"|"Pool Update")
                  println DEBUG "Pool name        : ${FG_LGRAY}$(jq -r '."pool-metadata".name' <<< ${offlineJSON})${NC}"
                  println DEBUG "Ticker           : ${FG_LGRAY}$(jq -r '."pool-metadata".ticker' <<< ${offlineJSON})${NC}"
                  println DEBUG "Pledge           : ${FG_LBLUE}$(formatLovelace "$(ADAToLovelace "$(jq -r '."pool-pledge"' <<< ${offlineJSON})")")${NC} ADA"
                  println DEBUG "Margin           : ${FG_LBLUE}$(jq -r '."pool-margin"' <<< ${offlineJSON})${NC} %"
                  println DEBUG "Cost             : ${FG_LBLUE}$(formatLovelace "$(ADAToLovelace "$(jq -r '."pool-cost"' <<< ${offlineJSON})")")${NC} ADA"
                  echo
                  ;;
                *)
                  [[ ${otx_type} = "Wallet De-Registration" ]] && println DEBUG "Amount returned  : ${FG_LBLUE}$(formatLovelace "$(jq -r '."amount-returned"' <<< ${offlineJSON})")${NC} ADA"
                  if [[ ${otx_type} = "Payment" ]]; then
                    println DEBUG "Source addr      : ${FG_LGRAY}$(jq -r '."source-address"' <<< ${offlineJSON})${NC}"
                    println DEBUG "Destination addr : ${FG_LGRAY}$(jq -r '."destination-address"' <<< ${offlineJSON})${NC}"
                    println DEBUG "Amount           : ${FG_LBLUE}$(formatLovelace "$(jq -r '.assets[] | select(.asset=="lovelace") | .amount' <<< ${offlineJSON})")${NC} ADA"
                    for otx_assets in $(jq -r '.assets[] | @base64' <<< "${offlineJSON}"); do
                      _jq() { base64 -d <<< ${otx_assets} | jq -r "${1}"; }
                      otx_asset=$(_jq '.asset')
                      [[ ${otx_asset} = "lovelace" ]] && continue
                      println DEBUG "                   ${FG_LBLUE}$(formatAsset "$(_jq '.amount')")${NC} ${FG_LGRAY}${otx_asset}${NC}"
                    done
                  fi
                  jq -er '.rewards' <<< ${offlineJSON} &>/dev/null && println DEBUG "Rewards          : ${FG_LBLUE}$(formatLovelace "$(jq -r '.rewards' <<< ${offlineJSON})")${NC} ADA"
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
                  jq -er '."drep-wallet-name"' <<< ${offlineJSON} &>/dev/null && println DEBUG "DRep Wallet      : ${FG_GREEN}$(jq -r '."drep-wallet-name"' <<< ${offlineJSON})${NC}"
                  jq -er '."drep-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "DRep ID          : ${FG_LGRAY}$(jq -r '."drep-id"' <<< ${offlineJSON})${NC}"
                  jq -er '."action-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Action ID        : ${FG_LGRAY}$(jq -r '."action-id"' <<< ${offlineJSON})${NC}"
                  jq -er '.vote' <<< ${offlineJSON} &>/dev/null && println DEBUG "Vote             : ${FG_LGRAY}$(jq -r '.vote' <<< ${offlineJSON})${NC}"
                  echo
                  ;;
              esac
              println DEBUG "Signing keys required:"
              for otx_signing_name_b64 in $(jq -r '."signing-file"[].name | @base64' <<< "${offlineJSON}"); do
                otx_signing_name=$(base64 -d <<< "${otx_signing_name_b64}")
                unset hasWitness
                for otx_witness_name in $(jq -r '.witness[].name' <<< "${offlineJSON}"); do
                  [[ ${otx_witness_name} = "${otx_signing_name}" ]] && hasWitness=true && break
                done
                [[ -z ${hasWitness} ]] && println DEBUG "${FG_LGRAY}${otx_signing_name}${NC} ${FG_RED}${ICON_CROSS}${NC}" || println DEBUG "${FG_LGRAY}${otx_signing_name}${NC} ${FG_GREEN}${ICON_CHECK}${NC}"
              done
              for otx_script in $(jq -r '."script-file"[] | @base64' <<< "${offlineJSON}"); do
                _jq() { base64 -d <<< ${otx_script} | jq -r "${1}"; }
                otx_script_name=$(_jq '.name')
                otx_script_scripts="$(_jq '.script' 2>/dev/null)"
                getAllMultiSigKeys "${otx_script_scripts}"
                unset required_total
                validateMultiSigScript false "${otx_script_scripts}"
                println DEBUG "${FG_LGRAY}${otx_script_name}${NC} - required signatures: ${FG_LBLUE}${required_total}${NC}"
                for sig in "${!script_sig_list[@]}"; do
                  unset hasWitness found_wallet_name
                  for otx_witness_name in $(jq -r '.witness[].name' <<< "${offlineJSON}"); do
                    [[ ${otx_witness_name} = "${sig}" ]] && hasWitness=true && break
                  done
                  while IFS= read -r -d '' wallet; do
                    wallet_name=$(basename ${wallet})
                    getWalletType "${wallet_name}"
                    getCredentials "${wallet_name}"
                    getGovKeyInfo "${wallet_name}"
                    if [[ ${ms_pay_cred} = "${sig}" || ${ms_stake_cred} = "${sig}" || ${pay_cred} = "${sig}" || ${stake_cred} = "${sig}" || ${ms_drep_hash} = "${sig}" || ${drep_hash} = "${sig}" ]]; then
                      found_wallet_name="${wallet_name}"; break
                    fi
                  done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0)
                  [[ -z ${hasWitness} ]] && println DEBUG "  ${FG_LGRAY}${sig}${NC} ${FG_RED}${ICON_CROSS}${NC}" || println DEBUG "  ${FG_LGRAY}$([[ -n ${found_wallet_name} ]] && echo ${found_wallet_name} || echo ${sig})${NC} ${FG_GREEN}${ICON_CHECK}${NC}"
                done
              done

              [[ $(jq -r '."signed-txBody" | length' <<< ${offlineJSON}) -gt 0 ]] && println INFO "\n${FG_GREEN}${ICON_CHECK}${NC} Transaction already signed, please submit transaction to complete!" && waitToProceed && continue
              [[ $(date '+%s' --date="${otx_date_expire}") -lt $(date '+%s') ]] && println ERROR "\n${FG_RED}ERROR${NC}: Transaction expired!  please create a new one with long enough Time To Live (TTL)" && waitToProceed && continue

              for otx_signing_file in $(jq -r '."signing-file"[] | @base64' <<< "${offlineJSON}"); do
                _jq() { base64 -d <<< ${otx_signing_file} | jq -r "${1}"; }
                otx_signing_name=$(_jq '.name')
                otx_vkey_cborHex="$(_jq '.vkey.cborHex' 2>/dev/null)"
                skey_path=""
                for otx_witness in $(jq -r '.witness[] | @base64' <<< "${offlineJSON}"); do
                  __jq() { base64 -d <<< ${otx_witness} | jq -r "${1}"; }
                  [[ $(_jq '.name') = $(__jq '.name') ]] && continue 2 # offline transaction already witnessed by this signing key
                done
                # look for signing key in wallet folder
                while IFS= read -r -d '' w_file; do
                  if [[ ${w_file} = */"${WALLET_PAY_SK_FILENAME}" || ${w_file} = */"${WALLET_STAKE_SK_FILENAME}" || ${w_file} = */"${WALLET_GOV_DREP_SK_FILENAME}" ]]; then
                    ! ${CCLI} ${NETWORK_ERA} key verification-key --signing-key-file "${w_file}" --verification-key-file "${TMP_DIR}"/tmp.vkey && continue
                    if [[ $(jq -er '.type' "${w_file}" 2>/dev/null) = *"Extended"* ]]; then
                      ! ${CCLI} ${NETWORK_ERA} key non-extended-key --extended-verification-key-file "${TMP_DIR}/tmp.vkey" --verification-key-file "${TMP_DIR}/tmp2.vkey" && continue
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
                    ! ${CCLI} ${NETWORK_ERA} key verification-key --signing-key-file "${p_file}" --verification-key-file "${TMP_DIR}"/tmp.vkey && continue
                    grep -q "${otx_vkey_cborHex}" "${TMP_DIR}"/tmp.vkey && skey_path="${p_file}" && break
                  done < <(find "${POOL_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${POOL_COLDKEY_SK_FILENAME}" -print0 2>/dev/null)
                fi
                # look for signing key in asset folder
                if [[ -z ${skey_path} ]]; then
                  while IFS= read -r -d '' a_file; do
                    ! ${CCLI} ${NETWORK_ERA} key verification-key --signing-key-file "${a_file}" --verification-key-file "${TMP_DIR}"/tmp.vkey && continue
                    grep -q "${otx_vkey_cborHex}" "${TMP_DIR}"/tmp.vkey && skey_path="${a_file}" && break
                  done < <(find "${ASSET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${ASSET_POLICY_SK_FILENAME}" -print0 2>/dev/null)
                fi

                if [[ -n ${skey_path} ]]; then
                  println DEBUG "\nFound a match for ${otx_signing_name}, use this file ? : ${FG_LGRAY}${skey_path}${NC}"
                  select_opt "[y] Yes" "[s] Skip"
                  case $? in
                    0)  if ! witnessTx "${TMP_DIR}/tx.raw" "${skey_path}"; then waitToProceed && continue 2; fi
                        if ! offlineJSON=$(jq ".witness += [{ name: \"${otx_signing_name}\", witnessBody: $(jq -c . "${tx_witness_files[0]}") }]" <<< ${offlineJSON}); then return 1; fi
                        jq -r . <<< "${offlineJSON}" > "${offline_tx}" # save this witness to disk
                        continue ;;
                    1)  continue ;;
                  esac
                else
                  println DEBUG "\nDo you want to sign ${otx_type} with: ${FG_LGRAY}${otx_signing_name}${NC} ?"
                  select_opt "[y] Yes" "[s] Skip"
                  selection=$?
                fi
                [[ ${selection} -eq 1 ]] && continue
                if [[ ${otx_signing_name} = "Pool "* ]]; then dialog_start_path="${POOL_FOLDER}"
                elif [[ ${otx_signing_name} = "Asset "* ]]; then dialog_start_path="${ASSET_FOLDER}"
                else dialog_start_path="${WALLET_FOLDER}"; fi
                fileDialog "\nEnter path to ${otx_signing_name}" "${dialog_start_path}/"
                [[ ! -f "${file}" ]] && println ERROR "${FG_RED}ERROR${NC}: file not found: ${file}" && waitToProceed && continue 2
                if [[ ${file} = "${ASSET_POLICY_SCRIPT_FILENAME}" ]]; then
                  if ! grep -q "$(_jq '.script.keyHash')" "${file}"; then
                    println ERROR "${FG_RED}ERROR${NC}: script file provided doesn't match with script hash in transaction for: ${otx_signing_name}"
                    println ERROR "Provided asset script keyHash: $(jq -r '.keyHash' "${file}")"
                    println ERROR "Transaction asset script keyHash: $(_jq '.script.keyHash')"
                    waitToProceed && continue 2
                  fi
                elif [[ $(jq -er '.description' "${file}" 2>/dev/null) = *"Hardware"* ]]; then
                  if ! grep -q "${otx_vkey_cborHex:4}" "${file}"; then # strip 5820 prefix
                    println ERROR "${FG_RED}ERROR${NC}: signing key provided doesn't match with verification key in transaction for: ${otx_signing_name}"
                    println ERROR "Provided hardware signing key's verification cborXPubKeyHex: $(jq -r .cborXPubKeyHex "${file}")"
                    println ERROR "Transaction verification cborHex: ${otx_vkey_cborHex:4}"
                    waitToProceed && continue 2
                  fi
                else
                  println ACTION "${CCLI} ${NETWORK_ERA} key verification-key --signing-key-file ${file} --verification-key-file ${TMP_DIR}/tmp.vkey"
                  if ! stdout=$(${CCLI} ${NETWORK_ERA} key verification-key --signing-key-file "${file}" --verification-key-file "${TMP_DIR}"/tmp.vkey 2>&1); then
                    println ERROR "\n${FG_RED}ERROR${NC}: failure during verification key creation!\n${stdout}"; waitToProceed && continue 2
                  fi
                  if [[ $(jq -r '.type' "${file}") = *"Extended"* ]]; then
                    println ACTION "${CCLI} ${NETWORK_ERA} key non-extended-key --extended-verification-key-file ${TMP_DIR}/tmp.vkey --verification-key-file ${TMP_DIR}/tmp2.vkey"
                    if ! stdout=$(${CCLI} ${NETWORK_ERA} key non-extended-key --extended-verification-key-file "${TMP_DIR}/tmp.vkey" --verification-key-file "${TMP_DIR}/tmp2.vkey" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during non-extended verification key creation!\n${stdout}"; waitToProceed && continue 2
                    fi
                    mv -f "${TMP_DIR}/tmp2.vkey" "${TMP_DIR}/tmp.vkey"
                  fi
                  if [[ ${otx_vkey_cborHex} != $(jq -r .cborHex "${TMP_DIR}"/tmp.vkey) ]]; then
                    println ERROR "${FG_RED}ERROR${NC}: signing key provided doesn't match with verification key in transaction for: ${otx_signing_name}"
                    println ERROR "Provided signing key's verification cborHex: $(jq -r .cborHex "${TMP_DIR}"/tmp.vkey)"
                    println ERROR "Transaction verification cborHex: ${otx_vkey_cborHex}"
                    waitToProceed && continue 2
                  fi
                fi
                if ! witnessTx "${TMP_DIR}/tx.raw" "${file}"; then waitToProceed && continue 2; fi
                if ! offlineJSON=$(jq ".witness += [{ name: \"${otx_signing_name}\", witnessBody: $(jq -c . "${tx_witness_files[0]}") }]" <<< ${offlineJSON}); then return 1; fi
                jq -r . <<< "${offlineJSON}" > "${offline_tx}" # save this witness to disk
              done
              unset script_failed pay_script_signers stake_script_signers drep_script_signers
              for otx_script in $(jq -r '."script-file"[] | @base64' <<< "${offlineJSON}"); do
                _jq() { base64 -d <<< ${otx_script} | jq -r "${1}"; }
                otx_script_name=$(_jq '.name')
                otx_script_scripts="$(_jq '.script' 2>/dev/null)"
                getAllMultiSigKeys "${otx_script_scripts}"
                # loop once to add all already signed creds
                missing_creds=()
                script_sig_creds=()
                for sig in "${!script_sig_list[@]}"; do
                  for otx_witness in $(jq -r '.witness[] | @base64' <<< "${offlineJSON}"); do
                    __jq() { base64 -d <<< ${otx_witness} | jq -r "${1}"; }
                    [[ ${sig} = $(__jq '.name') ]] && script_sig_creds+=( ${sig} ) && continue 2 # offline transaction already witnessed by this signing key
                  done
                  missing_creds+=( "${sig}" )
                done
                # Check if script meets requirement
                if validateMultiSigScript false "${otx_script_scripts}" "${script_sig_creds[@]}"; then
                  # script successfully validated, no more signatures needed
                  println DEBUG "\n${FG_LGRAY}${otx_script_name}${NC} validation ${FG_GREEN}passed${NC}! No more signatures needed!"
                  continue
                fi
                # loop again if needed
                for sig in "${missing_creds[@]}"; do
                  # Check if script meets requirement
                  if validateMultiSigScript false "${otx_script_scripts}" "${script_sig_creds[@]}"; then
                    # script successfully validated, no more signatures needed
                    println DEBUG "\n${FG_LGRAY}${otx_script_name}${NC} validation ${FG_GREEN}passed${NC}! No more signatures needed!"
                    break
                  fi
                  unset skey_path
                  # look for matching credential in wallet folder
                  while IFS= read -r -d '' wallet; do
                    wallet_name=$(basename ${wallet})
                    getWalletType "${wallet_name}"
                    getCredentials "${wallet_name}"
                    getGovKeyInfo "${wallet_name}"
                    if [[ ${ms_pay_cred} = "${sig}" ]]; then
                      skey_path="${ms_payment_sk_file}"; break
                    elif [[ ${ms_stake_cred} = "${sig}" ]]; then
                      skey_path="${ms_stake_sk_file}"; break
                    elif [[ ${pay_cred} = "${sig}" ]]; then
                      skey_path="${payment_sk_file}"; break
                    elif [[ ${stake_cred} = "${sig}" ]]; then
                      skey_path="${stake_sk_file}"; break
                    elif [[ ${ms_drep_hash} = "${sig}" ]]; then
                      skey_path="${ms_drep_sk_file}"; break
                    elif [[ ${drep_hash} = "${sig}" ]]; then
                      skey_path="${drep_sk_file}"; break
                    fi
                  done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0)
                  [[ -n ${skey_path} && ! -f "${skey_path}" ]] && println ERROR "\n${FG_YELLOW}WARN${NC}: Wallet match found but signing key missing: ${skey_path}" && unset skey_path
                  # matching MultiSig participant wallet found?
                  if [[ -n ${skey_path} ]]; then
                    println DEBUG "\nFound a matching wallet for ${FG_LGRAY}${otx_script_name}${NC}, use this file ? : ${FG_LGRAY}${skey_path}${NC}"
                    select_opt "[y] Yes" "[s] Skip participant"
                    case $? in
                      0)  if ! witnessTx "${TMP_DIR}/tx.raw" "${skey_path}"; then waitToProceed && continue 2; fi
                          if ! offlineJSON=$(jq ".witness += [{ name: \"${sig}\", witnessBody: $(jq -c . "${tx_witness_files[0]}") }]" <<< ${offlineJSON}); then return 1; fi
                          jq -r . <<< "${offlineJSON}" > "${offline_tx}" # save this witness to disk
                          script_sig_creds+=( ${sig} )
                          continue ;;
                      1)  continue ;;
                    esac
                  else
                    println DEBUG "\nNo match found, continue with manual input to signature file for ${FG_LGRAY}${otx_script_name}${NC} with credential below?\n${FG_LGRAY}${sig}${NC}"
                    select_opt "[p] Enter path" "[s] Skip participant"
                    selection=$?
                  fi
                  if [[ ${selection} -eq 1 ]]; then
                    continue
                  else
                    # choose
                    fileDialog "\nEnter path to signing key for MultiSig participant" "${WALLET_FOLDER}/"
                    [[ ! -f "${file}" ]] && println ERROR "${FG_RED}ERROR${NC}: file not found: ${file}" && waitToProceed && continue 2
                    file_desc=$(jq -er '.description' "${file}" 2>/dev/null)
                    if [[ ${file_desc} = *"Hardware"* ]]; then
                      dir_path=$(dirname "${file}")
                      if ! vkey=$(jq -er .cborXPubKeyHex "${file}"); then
                        println ERROR "${FG_RED}ERROR${NC}: signing key provided is invalid, missing field 'cborXPubKeyHex'" && continue
                      fi
                      vkey=${vkey:4:64}
                      # find vkey file in same folder
                      if ! vkey_file=$(grep -l "cborHex.*${vkey}" "${dir_path}"/*); then
                        println ERROR "${FG_RED}ERROR${NC}: unable to find a matching verification key file for provided hardware signing key in same folder" && continue
                      fi
                      vkey_file=$(echo "${vkey_file}" | head -n 1) # make sure there is a single match
                      if [[ ${file_desc} = *"Payment"* ]]; then
                        cred_type=payment
                      elif [[ ${file_desc} = *"Stake"* ]]; then
                        cred_type=stake
                      else
                        cred_type=drep
                      fi
                      getCredential ${cred_type} ${vkey_file}
                    else
                      println ACTION "${CCLI} ${NETWORK_ERA} key verification-key --signing-key-file ${file} --verification-key-file ${TMP_DIR}/tmp.vkey"
                      if ! stdout=$(${CCLI} ${NETWORK_ERA} key verification-key --signing-key-file "${file}" --verification-key-file "${TMP_DIR}"/tmp.vkey 2>&1); then
                        println ERROR "\n${FG_RED}ERROR${NC}: failure during verification key creation!\n${stdout}"; waitToProceed && continue 2
                      fi
                      file_type=$(jq -r '.type' "${file}")
                      if [[ ${file_type} = *"Extended"* ]]; then
                        println ACTION "${CCLI} ${NETWORK_ERA} key non-extended-key --extended-verification-key-file ${TMP_DIR}/tmp.vkey --verification-key-file ${TMP_DIR}/tmp2.vkey"
                        if ! stdout=$(${CCLI} ${NETWORK_ERA} key non-extended-key --extended-verification-key-file "${TMP_DIR}/tmp.vkey" --verification-key-file "${TMP_DIR}/tmp2.vkey" 2>&1); then
                          println ERROR "\n${FG_RED}ERROR${NC}: failure during non-extended verification key creation!\n${stdout}"; waitToProceed && continue 2
                        fi
                        mv -f "${TMP_DIR}/tmp2.vkey" "${TMP_DIR}/tmp.vkey"
                      fi
                      if [[ ${file_desc} = *"Payment"* ]]; then
                        cred_type=payment
                      elif [[ ${file_desc} = *"Stake"* ]]; then
                        cred_type=stake
                      else
                        cred_type=drep
                      fi
                      getCredential ${cred_type} "${TMP_DIR}"/tmp.vkey
                    fi
                    if [[ ${cred} != "${sig}" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: signing key provided doesn't match with credential in MultiSig script:${FG_LGRAY}${otx_script_name}${NC}"
                      println ERROR "Provided signing key's credential  : ${FG_LGRAY}${cred}${NC}"
                      println ERROR "Looking for credential             : ${FG_LGRAY}${sig}${NC}"
                      waitToProceed && continue
                    fi
                    if ! witnessTx "${TMP_DIR}/tx.raw" "${file}"; then waitToProceed && continue 2; fi
                    if ! offlineJSON=$(jq ".witness += [{ name: \"${sig}\", witnessBody: $(jq -c . "${tx_witness_files[0]}") }]" <<< ${offlineJSON}); then return 1; fi
                    jq -r . <<< "${offlineJSON}" > "${offline_tx}" # save this witness to disk
                    script_sig_creds+=( ${sig} )
                  fi
                done
                unset required_total
                if ! validateMultiSigScript true "${otx_script_scripts}" "${script_sig_creds[@]}"; then
                  # script failed validation
                  script_failed=true
                  println ERROR "\n${FG_LGRAY}${otx_script_name}${NC} validation ${FG_RED}failed${NC}! Unable to submit transaction until needed signatures are added and/or time lock conditions if set pass!"
                  println DEBUG "If external participant signatures are needed, pass transaction file along to add additional signatures."
                  waitToProceed
                fi
                if [[ ${file_desc} = *"payment"* ]]; then
                  pay_script_signers=${required_total}
                elif [[ ${file_desc} = *"stake"* ]]; then
                  stake_script_signers=${required_total}
                else
                  drep_script_signers=${required_total}
                fi
              done
              signatures_needed=$(( $(jq -r '."signing-file" | length' <<< "${offlineJSON}") + pay_script_signers + stake_script_signers + drep_script_signers ))
              witness_cnt=$(jq -r '.witness | length' <<< "${offlineJSON}")
              if [[ ${witness_cnt} -ge ${signatures_needed} && -z ${script_failed} ]]; then # witnessed by all needed signing keys
                tx_witness_files=()
                for otx_witness in $(jq -r '.witness[] | @base64' <<< "${offlineJSON}"); do
                  _jq() { base64 -d <<< ${otx_witness} | jq -r "${1}"; }
                  tx_witness="$(mktemp "${TMP_DIR}/tx.witness_XXXXXXXXXX")"
                  jq -r . <<< "$(_jq '.witnessBody')" > "${tx_witness}"
                  tx_witness_files+=( "${tx_witness}" )
                done
                if ! assembleTx "${TMP_DIR}/tx.raw"; then waitToProceed && continue; fi
                if jq ". += { \"signed-txBody\": $(jq -c . "${tx_signed}") }" <<< "${offlineJSON}" > "${offline_tx}"; then
                  println "\nTransaction successfully assembled and signed by all needed signing keys"
                  println "please submit on online node before ${FG_LGRAY}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}!"
                else
                  println ERROR "${FG_RED}ERROR${NC}: failed to write signed tx body to offline transaction file!"
                fi
              else
                println "Transaction need to be signed by ${FG_LBLUE}${signatures_needed}${NC} signing keys, signed by ${FG_LBLUE}${witness_cnt}${NC} so far!"
              fi
              waitToProceed && continue
              ;; ###################################################################
            submit)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> TRANSACTION >> SUBMIT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              fi
              echo
              fileDialog "Enter path to offline tx file to submit" "${TMP_DIR}/" && echo
              offline_tx=${file}
              [[ -z "${offline_tx}" ]] && continue
              if [[ ! -f "${offline_tx}" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: file not found: ${offline_tx}"
                waitToProceed && continue
              elif ! offlineJSON=$(jq -erc . "${offline_tx}"); then
                println ERROR "${FG_RED}ERROR${NC}: invalid JSON file: ${offline_tx}"
                waitToProceed && continue
              fi
              if ! otx_type=$(jq -er '.type' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'type' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_date_created=$(jq -er '."date-created"' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'date-created' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_date_expire=$(jq -er '."date-expire"' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'date-expire' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_txFee=$(jq -er '.txFee' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'txFee' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_signed_txBody=$(jq -er '."signed-txBody"' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'signed-txBody' not found in: ${offline_tx}" && waitToProceed && continue; fi
              [[ $(jq 'length' <<< ${otx_signed_txBody}) -eq 0 ]] && println ERROR "${FG_RED}ERROR${NC}: transaction not signed, please sign transaction first!" && waitToProceed && continue
              println DEBUG "Transaction type : ${FG_YELLOW}${otx_type}${NC}"
              if jq -er '."wallet-name"' &>/dev/null <<< ${offlineJSON}; then 
                println DEBUG "Transaction fee  : ${FG_LBLUE}$(formatLovelace ${otx_txFee})${NC} ADA, payed by ${FG_GREEN}$(jq -r '."wallet-name"' <<< ${offlineJSON})${NC}"
              else
                println DEBUG "Transaction fee  : ${FG_LBLUE}$(formatLovelace ${otx_txFee})${NC} ADA"
              fi
              println DEBUG "Created          : ${FG_LGRAY}$(date '+%F %T %Z' --date="${otx_date_created}")${NC}"
              [[ $(date '+%s' --date="${otx_date_expire}") -lt $(date '+%s') ]] && expire_color="${FG_RED}" || expire_color="${FG_LGRAY}"
              println DEBUG "Expire           : ${expire_color}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}"
              echo
              [[ ${otx_type} = "Wallet De-Registration" ]] && println DEBUG "Amount returned  : ${FG_LBLUE}$(formatLovelace "$(jq -r '."amount-returned"' <<< ${offlineJSON})")${NC} ADA"
              if [[ ${otx_type} = "Payment" ]]; then
                println DEBUG "Source addr      : ${FG_LGRAY}$(jq -r '."source-address"' <<< ${offlineJSON})${NC}"
                println DEBUG "Destination addr : ${FG_LGRAY}$(jq -r '."destination-address"' <<< ${offlineJSON})${NC}"
                println DEBUG "Amount           : ${FG_LBLUE}$(formatLovelace "$(jq -r '.assets[] | select(.asset=="lovelace") | .amount' <<< ${offlineJSON})")${NC} ${FG_GREEN}ADA${NC}"
                for otx_assets in $(jq -r '.assets[] | @base64' <<< "${offlineJSON}"); do
                  _jq() { base64 -d <<< ${otx_assets} | jq -r "${1}"; }
                  otx_asset=$(_jq '.asset')
                  [[ ${otx_asset} = "lovelace" ]] && continue
                  println DEBUG "                   ${FG_LBLUE}$(formatAsset "$(_jq '.amount')")${NC} ${FG_LGRAY}${otx_asset}${NC}"
                done
              fi
              [[ ${otx_type} = "Wallet Rewards Withdrawal" ]] && println DEBUG "Rewards          : ${FG_LBLUE}$(formatLovelace "$(jq -r '.rewards' <<< ${offlineJSON})")${NC} ADA"
              jq -er '."pool-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Pool ID          : ${FG_LGRAY}$(jq -r '."pool-id"' <<< ${offlineJSON})${NC}"
              if jq -er '."pool-name"' <<< ${offlineJSON} &>/dev/null; then
                [[ ${otx_type} != "Pool Registration" ]] && println DEBUG "Pool name        : ${FG_LGRAY}$(jq -r '."pool-name"' <<< ${offlineJSON})${NC}"
              fi
              [[ ${otx_type} = "Pool De-Registration" ]] && println DEBUG "Ticker           : ${FG_LGRAY}$(jq -r '."pool-ticker"' <<< ${offlineJSON})${NC}"
              [[ ${otx_type} = "Pool De-Registration" ]] && println DEBUG "To be retired    : epoch ${FG_LGRAY}$(jq -r '."retire-epoch"' <<< ${offlineJSON})${NC}"
              jq -er '.metadata' <<< ${offlineJSON} &>/dev/null && println DEBUG "Metadata         :\n$(jq -r '.metadata' <<< ${offlineJSON})\n"
              [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Pool name        : ${FG_LGRAY}$(jq -r '."pool-metadata".name' <<< ${offlineJSON})${NC}"
              [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Ticker           : ${FG_LGRAY}$(jq -r '."pool-metadata".ticker' <<< ${offlineJSON})${NC}"
              [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Pledge           : ${FG_LBLUE}$(formatLovelace "$(ADAToLovelace "$(jq -r '."pool-pledge"' <<< ${offlineJSON})")")${NC} ADA"
              [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Margin           : ${FG_LBLUE}$(jq -r '."pool-margin"' <<< ${offlineJSON})${NC} %"
              [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Cost             : ${FG_LBLUE}$(formatLovelace "$(ADAToLovelace "$(jq -r '."pool-cost"' <<< ${offlineJSON})")")${NC} ADA"
              [[ ${otx_type} = "Asset Minting" || ${otx_type} = "Asset Burning" ]] && println DEBUG "Policy Name      : ${FG_LGRAY}$(jq -r '."policy-name"' <<< ${offlineJSON})${NC}"
              [[ ${otx_type} = "Asset Minting" || ${otx_type} = "Asset Burning" ]] && println DEBUG "Policy ID        : ${FG_LGRAY}$(jq -r '."policy-id"' <<< ${offlineJSON})${NC}"
              [[ ${otx_type} = "Asset Minting" || ${otx_type} = "Asset Burning" ]] && println DEBUG "Asset Name       : ${FG_LGRAY}$(jq -r '."asset-name"' <<< ${offlineJSON})${NC}"
              [[ ${otx_type} = "Asset Minting" ]] && println DEBUG "Assets To Mint   : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-amount"' <<< ${offlineJSON})")${NC}"
              [[ ${otx_type} = "Asset Minting" ]] && println DEBUG "Assets Minted    : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-minted"' <<< ${offlineJSON})")${NC}"
              [[ ${otx_type} = "Asset Burning" ]] && println DEBUG "Assets To Burn   : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-amount"' <<< ${offlineJSON})")${NC}"
              [[ ${otx_type} = "Asset Burning" ]] && println DEBUG "Assets Left      : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-minted"' <<< ${offlineJSON})")${NC}"
              if [[ ${otx_type} = "Asset Minting" || ${otx_type} = "Asset Burning" ]] && otx_metadata=$(jq -er '.metadata' <<< ${offlineJSON}); then println DEBUG "Metadata         : \n${otx_metadata}\n"; fi
              jq -er '."drep-wallet-name"' <<< ${offlineJSON} &>/dev/null && println DEBUG "DRep Wallet      : ${FG_GREEN}$(jq -r '."drep-wallet-name"' <<< ${offlineJSON})${NC}"
              jq -er '."drep-hash"' <<< ${offlineJSON} &>/dev/null && println DEBUG "DRep Hash        : ${FG_LGRAY}$(jq -r '."drep-hash"' <<< ${offlineJSON})${NC}"
              jq -er '."drep-id-cip105"' <<< ${offlineJSON} &>/dev/null && println DEBUG "DRep ID CIP-105  : ${FG_LGRAY}$(jq -r '."drep-id-cip105"' <<< ${offlineJSON})${NC}"
              jq -er '."drep-id-cip129"' <<< ${offlineJSON} &>/dev/null && println DEBUG "DRep ID CIP-129  : ${FG_LGRAY}$(jq -r '."drep-id-cip129"' <<< ${offlineJSON})${NC}"
              jq -er '."action-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Action ID        : ${FG_LGRAY}$(jq -r '."action-id"' <<< ${offlineJSON})${NC}"
              jq -er '."action-id-cip129"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Action ID CIP-129: ${FG_LGRAY}$(jq -r '."action-id-cip129"' <<< ${offlineJSON})${NC}"
              jq -er '.vote' <<< ${offlineJSON} &>/dev/null && println DEBUG "Vote             : ${FG_LGRAY}$(jq -r '.vote' <<< ${offlineJSON})${NC}"

              if [[ $(date '+%s' --date="${otx_date_expire}") -lt $(date '+%s') ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: Transaction expired!  please create a new one with long enough Time To Live (TTL)"
                waitToProceed && continue
              fi

              tx_signed="${TMP_DIR}/tx.signed_$(date +%s)"
              println DEBUG "\nProceed to submit transaction?"
              select_opt "[y] Yes" "[n] No"
              case $? in
                0) : ;;
                1) continue ;;
              esac
              echo -e "${otx_signed_txBody}" > "${tx_signed}"
              if ! submitTx "${tx_signed}"; then waitToProceed && continue; fi
              if [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]]; then
                if otx_pool_name=$(jq -er '."pool-name"' <<< ${offlineJSON}); then
                  if ! jq '."pool-reg-cert"' <<< "${offlineJSON}" > "${POOL_FOLDER}/${otx_pool_name}/${POOL_REGCERT_FILENAME}"; then println ERROR "${FG_RED}ERROR${NC}: failed to write pool cert to disk"; fi
                  [[ -f "${POOL_FOLDER}/${otx_pool_name}/${POOL_DEREGCERT_FILENAME}" ]] && rm -f "${POOL_FOLDER}/${otx_pool_name}/${POOL_DEREGCERT_FILENAME}" # delete de-registration cert if available
                else
                  println ERROR "${FG_RED}ERROR${NC}: field 'pool-name' not found in: ${offline_tx}"
                fi
              fi
              echo
              verifyTx
              echo
              println DEBUG "Delete submitted offline transaction file?"
              select_opt "[y] Yes" "[n] No"
              case $? in
                0) rm -f "${offline_tx}" ;;
                1) : ;;
              esac
              waitToProceed && continue
              ;; ###################################################################
          esac # transaction sub OPERATION
        done # Transaction loop
        ;; ###################################################################
      vote)
        while true; do # Vote loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> VOTE"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Voting and Governance\n"\
            " ) Governance  - on-chain governance according to CIP-1694"\
            " ) Catalyst    - project funding platform"\
            "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Vote Operation\n"
          select_opt "[g] Governance" "[c] Catalyst" "[h] Home"
          case $? in
            0) SUBCOMMAND="governance" ;;
            1) SUBCOMMAND="catalyst" ;;
            2) break ;;
          esac
          case $SUBCOMMAND in
            governance)
              while true; do # Governance loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> VOTE >> GOVERNANCE (CIP-1694)"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Governance\n"\
                  " ) Info & Status  - show wallet governance information and status"\
                  " ) Delegate       - delegate wallet vote power to a DRep (own, external, or one of the pre-defined 'abstain' / 'no confidence')"\
                  " ) List proposals - show a list of active proposals to vote on and their current vote status"\
                  " ) Cast Vote      - vote on governance actions as an SPO, DRep, or Committee member"\
                  " ) DRep Reg / Upd - register wallet as a DRep for voting or submit updated anchor data for already DRep registered wallet"\
                  " ) DRep Retire    - retire wallet as a DRep"\
                  " ) MultiSig DRep  - create a multi-participant (MultiSig) DRep coalition"\
                  " ) Derive Keys    - derive delegate representative (DRep) and committee member keys (if needed)"\
                  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select Governance Operation\n"
                select_opt "[i] Info & Status" "[d] Delegate" "[l] List Proposals" "[v] Cast vote" "[r] DRep Registration / Update" "[x] DRep Retire" "[m] MultiSig DRep" "[k] Derive Keys" "[b] Back" "[h] Home"
                case $? in
                  0) SUBCOMMAND="info-status" ;;
                  1) SUBCOMMAND="delegate" ;;
                  2) SUBCOMMAND="list-proposals" ;;
                  3) SUBCOMMAND="vote" ;;
                  4) SUBCOMMAND="drep-reg" ;;
                  5) SUBCOMMAND="drep-ret" ;;
                  6) SUBCOMMAND="create-ms-drep" ;;
                  7) SUBCOMMAND="derive-gov-keys" ;;
                  8) break ;;
                  9) break 2 ;;
                esac
                case $SUBCOMMAND in
                  info-status)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> INFO & STATUS"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    if ! versionCheck "9.0" "${PROT_VERSION}"; then
                      println INFO "${FG_YELLOW}Not yet in Conway era, please revisit once network has crossed into Cardano governance era!${NC}"; waitToProceed && continue
                    fi
                    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
                    println DEBUG "Select wallet (derive governance keys if missing)"
                    selectWallet "none"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    current_epoch=$(getEpoch)
                    drep_script_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_SCRIPT_FILENAME}"
                    if [[ ${CNTOOLS_MODE} != "OFFLINE" && ! -f "${drep_script_file}" ]]; then
                      println "DEBUG" "\nVote Delegation Status"
                      unset walletName
                      if getWalletVoteDelegation ${wallet_name}; then
                        unset vote_delegation_hash
                        vote_delegation_type="${vote_delegation%-*}"
                        if [[ ${vote_delegation} = always* ]]; then
                          if [[ ${vote_delegation} = alwaysAbstain ]]; then
                            println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Delegation" "Always abstain")"
                          else
                            println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Delegation" "Always no confidence")"
                          fi
                        else
                          if [[ ${vote_delegation} = *-* ]]; then
                            vote_delegation_hash="${vote_delegation#*-}"
                            while IFS= read -r -d '' _wallet; do
                              getGovKeyInfo "$(basename ${_wallet})"
                              if [[ ${drep_hash} = "${vote_delegation_hash}" ]]; then
                                walletName="$(basename ${_wallet})" && break
                              fi
                            done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
                          fi
                          getDRepIds ${vote_delegation_type} ${vote_delegation_hash}
                          println "$(printf "%-20s ${FG_DGRAY}: CIP-105 =>${NC} ${FG_LGRAY}%s${NC}" "Delegation" "${drep_id}")"
                          println "$(printf "%-20s ${FG_DGRAY}: CIP-129 =>${NC} ${FG_LGRAY}%s${NC}" "" "${drep_id_cip129}")"
                          if [[ -n ${walletName} ]]; then
                            println "$(printf "%-20s ${FG_DGRAY}: Wallet  =>${NC} ${FG_GREEN}%s${NC}" "" "${walletName}")"
                          fi
                          if [[ ${vote_delegation_type} = keyHash ]]; then
                            println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "DRep Type" "Key")"
                          else
                            println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "DRep Type" "MultiSig")"
                          fi
                          if getDRepStatus ${vote_delegation_type} ${vote_delegation_hash}; then
                            [[ ${current_epoch} -lt ${drep_expiry} ]] && expire_status="${FG_GREEN}active${NC}" || expire_status="${FG_RED}inactive${NC} (vote power does not count)"
                            println "$(printf "%-20s ${FG_DGRAY}:${NC} epoch ${FG_LBLUE}%s${NC} - %s" "DRep expiry" "${drep_expiry}" "${expire_status}")"
                            if [[ -n ${drep_anchor_url} ]]; then
                              println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "DRep anchor url" "${drep_anchor_url}")"
                              getDRepAnchor "${drep_anchor_url}" "${drep_anchor_hash}"
                              case $? in
                                0) println "$(printf "%-20s ${FG_DGRAY}:${NC}\n${FG_LGRAY}" "DRep anchor data")"
                                  jq -er "${drep_anchor_file}" 2>/dev/null || cat "${drep_anchor_file}"
                                  println DEBUG "${NC}"
                                  ;;
                                1) println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC}" "DRep anchor data" "Invalid URL or currently not available")" ;;
                                2) println "$(printf "%-20s ${FG_DGRAY}:${NC}\n${FG_LGRAY}" "DRep anchor data")"
                                  jq -er "${drep_anchor_file}" 2>/dev/null || cat "${drep_anchor_file}"
                                  println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC}" "DRep anchor hash" "mismatch")"
                                  println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "  registered" "${drep_anchor_hash}")"
                                  println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "  actual" "${drep_anchor_real_hash}")"
                                  ;;
                              esac
                            fi
                          else
                            println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_RED}%s${NC}" "Status" "Unable to get DRep status, retired?")"
                          fi
                        fi
                        getDRepVotePower ${vote_delegation_type} ${vote_delegation_hash}
                        println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LBLUE}%s${NC} ADA (${FG_LBLUE}%s${NC} %%)" "Active Vote power" "$(formatLovelace ${vote_power:=0})" "${vote_power_pct:=0}")"
                      else
                        if versionCheck "10.0" "${PROT_VERSION}"; then 
                          println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC} - %s" "Delegation" "undelegated" "please note that reward withdrawals will not work until wallet is vote delegated")"
                        else
                          println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC}" "Delegation" "undelegated")"
                        fi
                      fi
                    fi
                    getGovKeyInfo ${wallet_name}
                    println "DEBUG" "\nOwn DRep Status"
                    if [[ -z ${drep_id} ]]; then
                      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC}" "Status" "Governance keys missing, please derive them if needed")"
                      waitToProceed && continue
                    fi
                    println "$(printf "%-20s ${FG_DGRAY}: CIP-105 =>${NC} ${FG_LGRAY}%s${NC}" "DRep ID" "${drep_id}")"
                    println "$(printf "%-20s ${FG_DGRAY}: CIP-129 =>${NC} ${FG_LGRAY}%s${NC}" "" "${drep_id_cip129}")"
                    println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "DRep Hash" "${drep_hash}")"
                    if [[ ${hash_type} = keyHash ]]; then
                      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "DRep Type" "Key")"
                    else
                      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "DRep Type" "MultiSig")"
                    fi
                    if [[ ${CNTOOLS_MODE} != "OFFLINE" ]]; then
                      if getDRepStatus ${hash_type} ${drep_hash}; then
                        [[ ${current_epoch} -lt ${drep_expiry} ]] && expire_status="${FG_GREEN}active${NC}" || expire_status="${FG_RED}inactive${NC} (vote power does not count)"
                        println "$(printf "%-20s ${FG_DGRAY}:${NC} epoch ${FG_LBLUE}%s${NC} - %s" "DRep expiry" "${drep_expiry}" "${expire_status}")"
                        if [[ -n ${drep_anchor_url} ]]; then
                          println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "DRep anchor url" "${drep_anchor_url}")"
                          getDRepAnchor "${drep_anchor_url}" "${drep_anchor_hash}"
                          case $? in
                            0) println "$(printf "%-20s ${FG_DGRAY}:${NC}\n${FG_LGRAY}" "DRep anchor data")"
                              jq -er "${drep_anchor_file}" 2>/dev/null || cat "${drep_anchor_file}"
                              println DEBUG "${NC}"
                              ;;
                            1) println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC}" "DRep anchor data" "Invalid URL or currently not available")" ;;
                            2) println "$(printf "%-20s ${FG_DGRAY}:${NC}\n${FG_LGRAY}" "DRep anchor data")"
                              jq -er "${drep_anchor_file}" 2>/dev/null || cat "${drep_anchor_file}"
                              println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC}" "DRep anchor hash" "mismatch")"
                              println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "  registered" "${drep_anchor_hash}")"
                              println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "  actual" "${drep_anchor_real_hash}")"
                              ;;
                          esac
                        fi
                        getDRepVotePower ${hash_type} ${drep_hash}
                        println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LBLUE}%s${NC} ADA (${FG_LBLUE}%s${NC} %%)" "Active Vote power" "$(formatLovelace ${vote_power:=0})" "${vote_power_pct:=0}")"
                      else
                        println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC}" "Status" "DRep key not registered")"
                      fi
                    fi
                    if [[ -n ${cc_cold_id} ]]; then
                      echo
                      println "$(printf "%-20s ${FG_DGRAY}: CIP-105 =>${NC} ${FG_LGRAY}%s${NC}" "Committee Cold ID" "${cc_cold_id}")"
                      println "$(printf "%-20s ${FG_DGRAY}: CIP-129 =>${NC} ${FG_LGRAY}%s${NC}" "" "${cc_cold_id_cip129}")"
                      println "$(printf "%-20s ${FG_DGRAY}: CIP-105 =>${NC} ${FG_LGRAY}%s${NC}" "Committee Hot ID" "${cc_hot_id}")"
                      println "$(printf "%-20s ${FG_DGRAY}: CIP-129 =>${NC} ${FG_LGRAY}%s${NC}" "" "${cc_hot_id_cip129}")"
                    fi
                    waitToProceed && continue
                    ;; ###################################################################
                  delegate)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> DELEGATE"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    unset drep_id_cip129
                    if ! versionCheck "9.0" "${PROT_VERSION}"; then
                      println INFO "\n${FG_YELLOW}Not yet in Conway era, please revisit once network has crossed into Cardano governance era!${NC}"; waitToProceed && continue
                    fi
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    println DEBUG "\nSelect wallet"
                    selectWallet "balance" "${WALLET_STAKE_VK_FILENAME}"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    _wallet_name="${wallet_name}"
                    if ! isWalletRegistered ${wallet_name}; then
                      if [[ ${op_mode} = "online" ]]; then
                        # maybe this block below should be a part of registerStakeWallet?
                        getWalletBalance ${wallet_name} true true false true
                        if [[ ${base_lovelace} -lt ${KEY_DEPOSIT} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: insufficient funds (${base_lovelace}) available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                          println DEBUG "Funds for key deposit($(formatLovelace ${KEY_DEPOSIT}) ADA) + transaction fee needed to register the wallet"
                          waitToProceed && continue
                        fi

                        if ! registerStakeWallet ${wallet_name}; then waitToProceed && continue; fi
                      else
                        println ERROR "\n${FG_YELLOW}The wallet is not a registered wallet on chain and CNTools run in hybrid mode${NC}"
                        println ERROR "Please first register the wallet using 'Wallet >> Register'"
                        waitToProceed && continue
                      fi
                    fi
                    unset drep_wallet drep_hash
                    println DEBUG "\nDo you want to delegate to a local CNTools DRep registered wallet, pre-defined type or specify the DRep?"
                    select_opt "[w] CNTools DRep Wallet" "[i] DRep ID" "[a] Always Abstain" "[c] Always No Confidence" "[Esc] Cancel"
                    case $? in
                      0) selectWallet "none"
                        case $? in
                          1) waitToProceed; continue ;;
                          2) continue ;;
                        esac
                        drep_wallet="${wallet_name}"
                        wallet_name="${_wallet_name}"
                        getGovKeyInfo "${drep_wallet}"
                        if [[ -z ${drep_id} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: unable to get DRep id from selected wallet :("
                          waitToProceed && continue
                        fi
                        ;;
                      1) getAnswerAnyCust drep_id "DRep ID [CIP-105 or CIP-129] (blank to cancel)"
                        [[ -z "${drep_id}" ]] && continue
                        parseDRepId "${drep_id}"
                        [[ -z ${drep_id} ]] && println ERROR "\n${FG_RED}ERROR${NC}: invalid DRep ID entered!" && waitToProceed && continue
                        ;;
                      2) drep_id="alwaysAbstain"; vote_param_arr=("--always-abstain") ;;
                      3) drep_id="alwaysNoConfidence"; vote_param_arr=("--always-no-confidence") ;;
                      4) continue ;;
                    esac
                    unset drep_expiry
                    if [[ ${drep_id} != always* ]]; then
                      getDRepStatus ${hash_type} ${drep_hash}
                      if [[ -z ${drep_expiry} ]]; then
                        println ERROR "\n${FG_RED}ERROR${NC}: selected DRep not registered"
                        waitToProceed && continue
                      fi
                      if [[ $(getEpoch) -ge ${drep_expiry} ]]; then
                        println ERROR "\n${FG_YELLOW}WARN${NC}: selected DRep is marked as inactive and its vote power doesn't currently count, continue anyway?"
                        select_opt "[y] Yes" "[n] No"
                        case $? in
                          0) : ;; # do nothing
                          1) continue ;;
                        esac
                      fi
                      [[ ${hash_type} = keyHash ]] && vote_param_arr=("--drep-key-hash" "${drep_hash}") || vote_param_arr=("--drep-script-hash" "${drep_hash}")
                      getDRepVotePower keyHash ${drep_hash}
                      [[ -z ${vote_power} ]] && getDRepVotePower scriptHash ${drep_hash}
                      if [[ -z ${vote_power} ]]; then
                        println ERROR "\n${FG_YELLOW}WARN${NC}: selected DRep has no active vote power associated with it, continue?"
                        select_opt "[y] Yes" "[n] No"
                        case $? in
                          0) : ;; # do nothing
                          1) continue ;;
                        esac
                      fi
                    else
                      getDRepVotePower "${drep_id}"
                    fi
                    getWalletBalance ${wallet_name} true true false true
                    if [[ ${base_lovelace} -le 0 ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                      println DEBUG "Funds for transaction fee needed to create vote delegation transaction"
                      waitToProceed && continue
                    fi
                    if ! voteDelegation; then
                      [[ -f ${vote_deleg_cert_file} ]] && rm -f ${vote_deleg_cert_file}
                      waitToProceed && continue
                    fi
                    echo
                    if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
                    echo
                    println "${FG_GREEN}${wallet_name}${NC} successfully delegated to DRep!"
                    echo
                    println "DRep ID                : CIP-105 => ${FG_LGRAY}${drep_id}${NC}"
                    if [[ -n ${drep_id_cip129} ]]; then
                      println "                       : CIP-129 => ${FG_LGRAY}${drep_id_cip129}${NC}"
                    fi
                    if [[ -n ${drep_expiry} ]]; then
                      [[ $(getEpoch) -lt ${drep_expiry} ]] && expire_status="${FG_GREEN}active${NC}" || expire_status="${FG_RED}inactive${NC} (vote power does not count)"
                      println "DRep expiry            : epoch ${FG_LBLUE}${drep_expiry}${NC} - ${expire_status}"
                    fi
                    println "Active DRep vote power : ${FG_LBLUE}$(formatLovelace ${vote_power:=0})${NC} ADA (${FG_LBLUE}${vote_power_pct:=0} %${NC})"
                    waitToProceed && continue
                    ;; ###################################################################
                  list-proposals)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> LIST PROPOSALS"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    tput sc && println DEBUG "Querying for list of proposals...\n"
                    getAllGovActions
                    tput rc && tput ed
                    action_cnt=${#vote_action_list[@]}
                    if [[ ${action_cnt} -eq 0 ]]; then
                      println "${FG_YELLOW}No active proposals to vote on!${NC}"
                      waitToProceed && continue
                    fi
                    if [[ ${action_cnt} -gt 3 ]]; then
                      getAnswerAnyCust page_entries "${action_cnt} proposals found. Enter number of actions to display per page (enter for 3)"
                    fi
                    page_entries=${page_entries:=3}
                    if ! isNumber ${page_entries} || [[ ${page_entries} -lt 1 ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: invalid number"
                      waitToProceed && continue
                    fi
                    curr_epoch=$(getEpoch)
                    page=1
                    pages=$(( (action_cnt + (page_entries - 1)) / page_entries ))
                    while true; do
                      clear
                      if [[ ${show_details} = Y ]]; then
                        tput sc && println DEBUG "\nFetching proposal details and metadata...\n"
                        getGovAction "${action_tx_id}" "${action_idx}"
                        res=$?
                        tput rc && tput ed
                        case ${res} in
                          1) println ERROR "\n${FG_RED}ERROR${NC}: governance action id not found!"
                             waitToProceed && continue ;;
                          2) println ERROR "\n${FG_YELLOW}WARN${NC}: invalid governance action proposal anchor url or content"
                             println DEBUG "URL : ${FG_LGRAY}${proposal_url}${NC}"
                             waitToProceed ;;
                          3) println ERROR "\n${FG_YELLOW}WARN${NC}: invalid governance action proposal anchor hash"
                             println DEBUG "Action hash : ${FG_LGRAY}${proposal_hash}${NC}"
                             println DEBUG "Real hash   : ${FG_LGRAY}${proposal_meta_hash}${NC}"
                             waitToProceed ;;
                        esac
                        println DEBUG "\nGovernance Action Details${FG_LGRAY}"
                        jq -er <<< "${vote_action}" 2>/dev/null || echo "${vote_action}"
                        println DEBUG "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                        if [[ -f "${proposal_meta_file}" ]]; then
                          println DEBUG "\nGovernance Action Anchor Content${FG_LGRAY}"
                          jq -er "${proposal_meta_file}" 2>/dev/null || cat "${proposal_meta_file}"
                        fi
                        unset show_details
                        waitToProceed && continue
                      fi
                      start_idx=$(( (page *  page_entries) - page_entries ))
                      # loop current page to find max length of entries
                      max_len=70 # assume action id in CIP-129 format (70)
                      total_len=$(( max_len + 13 + 5 ))
                      border_line="|$(printf "%${total_len}s" "" | tr " " "=")|" # max value length + longest title (13) + spacing (5)
                      println DEBUG "Current epoch : ${FG_LBLUE}$(getEpoch)${NC}"
                      println DEBUG "Proposals     : ${FG_LBLUE}${action_cnt}${NC}"
                      idx=1
                      for vote_action in "${vote_action_list[@]:${start_idx}:${page_entries}}"; do
                        println DEBUG "\n${border_line}"
                        # calculate length of strings
                        IFS=',' read -r action_id action_type proposed_in expires_after anchor_url drep_yes drep_yes_power drep_yes_pct drep_no drep_no_power drep_no_pct spo_yes spo_yes_power spo_yes_pct spo_no spo_no_power spo_no_pct cc_yes cc_yes_pct cc_no cc_no_pct drep_vt spo_vt cc_vt isParameterSecurityGroup <<< "${vote_action}"
                        max_yes_len=${#drep_yes}
                        max_no_len=${#drep_no}
                        [[ ${#spo_yes} -gt ${max_yes_len} ]] && max_yes_len=${#spo_yes}
                        [[ ${#spo_no} -gt ${max_no_len} ]] && max_no_len=${#spo_no}
                        [[ ${#cc_yes} -gt ${max_yes_len} ]] && max_yes_len=${#cc_yes}
                        [[ ${#cc_no} -gt ${max_no_len} ]] && max_no_len=${#cc_no}
                        drep_yes_power="$(formatLovelaceHuman ${drep_yes_power})"; max_yes_power_len=${#drep_yes_power}
                        drep_no_power="$(formatLovelaceHuman ${drep_no_power})"; max_no_power_len=${#drep_no_power}
                        spo_yes_power="$(formatLovelaceHuman ${spo_yes_power})"; [[ ${#spo_yes_power} -gt ${max_yes_power_len} ]] && max_yes_power_len=${#spo_yes_power}
                        spo_no_power="$(formatLovelaceHuman ${spo_no_power})"; [[ ${#spo_no_power} -gt ${max_no_power_len} ]] && max_no_power_len=${#spo_no_power}
                        max_yes_pct_len=${#drep_yes_pct}
                        max_no_pct_len=${#drep_no_pct}
                        [[ ${#spo_yes_pct} -gt ${max_yes_pct_len} ]] && max_yes_pct_len=${#spo_yes_pct}
                        [[ ${#spo_no_pct} -gt ${max_no_pct_len} ]] && max_no_pct_len=${#spo_no_pct}
                        [[ ${#cc_yes_pct} -gt ${max_yes_pct_len} ]] && max_yes_pct_len=${#cc_yes_pct}
                        [[ ${#cc_no_pct} -gt ${max_no_pct_len} ]] && max_no_pct_len=${#cc_no_pct}
                        max_vt_len=${#drep_vt}
                        [[ ${#spo_vt} -gt ${max_vt_len} ]] && max_vt_len=${#spo_vt}
                        [[ ${#cc_vt} -gt ${max_vt_len} ]] && max_vt_len=${#cc_vt}
                        anchor_url_arr=()
                        anchor_url_start=0
                        while true; do
                          anchor_url_chunk=${anchor_url:${anchor_url_start}:${max_len}}
                          [[ -z ${anchor_url_chunk} ]] && break
                          anchor_url_arr+=( ${anchor_url_chunk} )
                          anchor_url_start=$(( anchor_url_start + max_len ))
                        done
                        # print data
                        IFS='#' read -r proposal_tx_id proposal_index <<< "${action_id}"
                        getGovActionId ${proposal_tx_id} ${proposal_index}
                        printf "| %-13s : ${FG_LGRAY}%-${max_len}s${NC} |\n" "Action ID" "${action_id}"
                        printf "| %-13s : ${FG_LGRAY}%-${max_len}s${NC} |\n" "  CIP-129" "${action_id_cip129}"
                        printf "| %-13s : ${FG_LGRAY}%-${max_len}s${NC} |\n" "Type" "${action_type}"
                        printf "| %-13s : ${FG_LGRAY}epoch${NC} ${FG_LBLUE}%-$(( max_len - 6 ))s${NC} |\n" "Proposed In" "${proposed_in}"
                        if [[ ${expires_after} -lt ${curr_epoch} ]]; then
                          printf "| %-13s : ${FG_LGRAY}epoch${NC} ${FG_RED}%-$(( max_len - 6 ))s${NC} |\n" "Expires After" "${expires_after}"
                        else
                          printf "| %-13s : ${FG_LGRAY}epoch${NC} ${FG_LBLUE}%-$(( max_len - 6 ))s${NC} |\n" "Expires After" "${expires_after}"
                        fi
                        for i in "${!anchor_url_arr[@]}"; do
                          [[ $i -eq 0 ]] && anchor_label="Anchor URL" || anchor_label=""
                          printf "| %-13s : ${FG_LGRAY}%-${max_len}s${NC} |\n" "${anchor_label}" "${anchor_url_arr[$i]}"
                        done
                        three_col_width=$(( max_len / 3 ))
                        three_col_start=18
                        three_col_2_start=$(( three_col_start + three_col_width ))
                        three_col_3_start=$(( three_col_2_start + three_col_width ))
                        # Header
                        printf "|${FG_LGRAY}$(printf "%17s" "" | tr " " "-")${NC}${FG_BLACK}\e[42mYES${NC}${FG_LGRAY}$(printf "%$((three_col_width-3))s" " " | tr " " "-")${NC}${FG_BLACK}\e[41mNO${NC}${FG_LGRAY}$(printf "%$((three_col_width-2))s" "" | tr " " "-")${NC}${FG_BLACK}\e[47mSTATUS${NC}${FG_LGRAY}$(printf "%$(((max_len-(2*three_col_width))-5))s" "" | tr " " "-")${NC}|\n"
                        tput sc
                        if isAllowedToVote "drep" "${action_type}" "${isParameterSecurityGroup:=N}"; then
                          # DRep YES
                          printf "| %-13s : ${FG_LBLUE}%-${max_yes_len}s${NC} ${FG_LGRAY}@${NC} ${FG_LBLUE}%${max_yes_power_len}s${NC} ${FG_LGRAY}VP${NC}" "DRep" "${drep_yes}" "${drep_yes_power}"
                          # move to second column
                          tput rc && tput cuf ${three_col_2_start}
                          # DRep NO
                          printf "${FG_LBLUE}%-${max_no_len}s${NC} ${FG_LGRAY}@${NC} ${FG_LBLUE}%${max_no_power_len}s${NC} ${FG_LGRAY}VP${NC}" "${drep_no}" "${drep_no_power}"
                          # move to third column
                          tput rc && tput cuf ${three_col_3_start}
                          # DRep STATUS
                          if [[ -n ${drep_vt} ]]; then
                            (( $(bc -l <<< "${drep_yes_pct} >= ${drep_vt}") )) && printf "${FG_GREEN}${ICON_CHECK}${NC} " || printf "${FG_RED}${ICON_CROSS}${NC} "
                          fi
                          printf "${FG_LBLUE}%s${NC} ${FG_LGRAY}%-$((max_yes_pct_len-${#drep_yes_pct}+1))s${NC}" "${drep_yes_pct}" "%"
                          if [[ -n ${drep_vt} ]]; then
                            printf " ${FG_LGRAY}VT:${NC} ${FG_LBLUE}%s${NC} ${FG_LGRAY}%-$((max_vt_len-${#drep_vt}+1))s${NC}" "${drep_vt}" "%"
                          fi
                          # move to end and close line
                          tput rc && tput cuf ${total_len} && printf " |\n"
                        else
                          printf "| %-13s : ${FG_DGRAY}N|A${NC}" 'DRep'
                          # move to second column and print NA
                          tput rc && tput cuf ${three_col_2_start} && printf "${FG_DGRAY}N|A${NC}"
                          # move to third column and print NA
                          tput rc && tput cuf ${three_col_3_start} && printf "${FG_DGRAY}N|A${NC}"
                          # move to end and close line
                          tput rc && tput cuf ${total_len} && printf " |\n"
                        fi
                        tput sc
                        if isAllowedToVote "spo" "${action_type}" "${isParameterSecurityGroup:=N}"; then
                          # SPO YES
                          printf "| %-13s : ${FG_LBLUE}%-${max_yes_len}s${NC} ${FG_LGRAY}@${NC} ${FG_LBLUE}%${max_yes_power_len}s${NC} ${FG_LGRAY}VP${NC}" "SPO" "${spo_yes}" "${spo_yes_power}"
                          # move to second column
                          tput rc && tput cuf ${three_col_2_start}
                          # SPO NO
                          printf "${FG_LBLUE}%-${max_no_len}s${NC} ${FG_LGRAY}@${NC} ${FG_LBLUE}%${max_no_power_len}s${NC} ${FG_LGRAY}VP${NC}" "${spo_no}" "${spo_no_power}"
                          # move to third column
                          tput rc && tput cuf ${three_col_3_start}
                          # SPO STATUS
                          if [[ -n ${spo_vt} ]]; then
                            (( $(bc -l <<< "${spo_yes_pct} >= ${spo_vt}") )) && printf "${FG_GREEN}${ICON_CHECK}${NC} " || printf "${FG_RED}${ICON_CROSS}${NC} "
                          fi
                          printf "${FG_LBLUE}%s${NC} ${FG_LGRAY}%-$((max_yes_pct_len-${#spo_yes_pct}+1))s${NC}" "${spo_yes_pct}" "%"
                          if [[ -n ${spo_vt} ]]; then
                            printf " ${FG_LGRAY}VT:${NC} ${FG_LBLUE}%s${NC} ${FG_LGRAY}%-$((max_vt_len-${#spo_vt}+1))s${NC}" "${spo_vt}" "%"
                          fi
                          # move to end and close line
                          tput rc && tput cuf ${total_len} && printf " |\n"
                        else
                          printf "| %-13s : ${FG_DGRAY}N|A${NC}" 'SPO'
                          # move to second column and print NA
                          tput rc && tput cuf ${three_col_2_start} && printf "${FG_DGRAY}N|A${NC}"
                          # move to third column and print NA
                          tput rc && tput cuf ${three_col_3_start} && printf "${FG_DGRAY}N|A${NC}"
                          # move to end and close line
                          tput rc && tput cuf ${total_len} && printf " |\n"
                        fi
                        tput sc
                        if isAllowedToVote "committee" "${action_type}" "${isParameterSecurityGroup:=N}"; then
                          # CC YES
                          printf "| %-13s : ${FG_LBLUE}%-${max_yes_len}s${NC}" "Committee" "${cc_yes}"
                          # move to second column
                          tput rc && tput cuf ${three_col_2_start}
                          # CC NO
                          printf "${FG_LBLUE}%-${max_no_len}s${NC}" "${cc_no}"
                          # move to third column
                          tput rc && tput cuf ${three_col_3_start}
                          # CC STATUS
                          if [[ -n ${cc_vt} ]]; then
                            (( $(bc -l <<< "${cc_yes_pct} >= ${cc_vt}") )) && printf "${FG_GREEN}${ICON_CHECK}${NC} " || printf "${FG_RED}${ICON_CROSS}${NC} "
                          fi
                          printf "${FG_LBLUE}%s${NC} ${FG_LGRAY}%-$((max_yes_pct_len-${#cc_yes_pct}+1))s${NC}" "${cc_yes_pct}" "%"
                          if [[ -n ${cc_vt} ]]; then
                            printf " ${FG_LGRAY}VT:${NC} ${FG_LBLUE}%s${NC} ${FG_LGRAY}%-$((max_vt_len-${#cc_vt}+1))s${NC}" "${cc_vt}" "%"
                          fi
                          # move to end and close line
                          tput rc && tput cuf ${total_len} && printf " |\n"
                        else
                          printf "| %-13s : ${FG_DGRAY}N|A${NC}" 'Committee'
                          # move to second column and print NA
                          tput rc && tput cuf ${three_col_2_start} && printf "${FG_DGRAY}N|A${NC}"
                          # move to third column and print NA
                          tput rc && tput cuf ${three_col_3_start} && printf "${FG_DGRAY}N|A${NC}"
                          # move to end and close line
                          tput rc && tput cuf ${total_len} && printf " |\n"
                        fi
                        unset printed_own
                        for own_vote in ${own_spo_votes}; do
                          if [[ ${own_vote} = "${action_id}"* ]]; then
                            IFS=';' read -ra own_vote_arr <<< "${own_vote}"
                            [[ -z ${printed_own} ]] && printf "|$(printf "%${total_len}s" "" | tr " " "-")|\n" && printed_own=Y
                            if [[ ${own_vote_arr[2]} = Yes ]]; then vote_color="${FG_GREEN}"; elif [[ ${own_vote_arr[2]} = No ]]; then vote_color="${FG_RED}"; else vote_color="${FG_DGRAY}"; fi
                            tput sc
                            printf "| You voted ${vote_color}%s${NC} with pool ${FG_GREEN}%s${NC}" "${own_vote_arr[2]}" "${own_vote_arr[1]}"
                            tput rc && tput cuf ${total_len} && printf " |\n"
                          fi
                        done
                        for own_vote in ${own_drep_votes}; do
                          if [[ ${own_vote} = "${action_id}"* ]]; then
                            IFS=';' read -ra own_vote_arr <<< "${own_vote}"
                            [[ -z ${printed_own} ]] && printf "|$(printf "%${total_len}s" "" | tr " " "-")|\n" && printed_own=Y
                            if [[ ${own_vote_arr[2]} = Yes ]]; then vote_color="${FG_GREEN}"; elif [[ ${own_vote_arr[2]} = No ]]; then vote_color="${FG_RED}"; else vote_color="${FG_DGRAY}"; fi
                            tput sc
                            printf "| You voted ${vote_color}%s${NC} with DRep wallet ${FG_GREEN}%s${NC}" "${own_vote_arr[2]}" "${own_vote_arr[1]}"
                            tput rc && tput cuf ${total_len} && printf " |\n"
                          fi
                        done
                        for own_vote in ${own_cc_votes}; do
                          if [[ ${own_vote} = "${action_id}"* ]]; then
                            IFS=';' read -ra own_vote_arr <<< "${own_vote}"
                            [[ -z ${printed_own} ]] && printf "|$(printf "%${total_len}s" "" | tr " " "-")|\n" && printed_own=Y
                            if [[ ${own_vote_arr[2]} = Yes ]]; then vote_color="${FG_GREEN}"; elif [[ ${own_vote_arr[2]} = No ]]; then vote_color="${FG_RED}"; else vote_color="${FG_DGRAY}"; fi
                            tput sc
                            printf "| You voted ${vote_color}%s${NC} with committee wallet ${FG_GREEN}%s${NC}" "${own_vote_arr[2]}" "${own_vote_arr[1]}"
                            tput rc && tput cuf ${total_len} && printf " |\n"
                          fi
                        done
                        println DEBUG "${border_line}"
                      done
                      println DEBUG "\n${FG_GREEN}YES${NC}    = Total power of 'yes' votes."
                      println DEBUG "${FG_RED}NO${NC}     = Total power of 'no' votes, including buckets of 'no vote cast' and 'always no confidence'."
                      println DEBUG "         ${FG_LGRAY}For motion of no confidence, 'always no confidence' power is switched to yes bucket.${NC}"
                      println DEBUG "${FG_DGRAY}STATUS${NC} = Percent of yes votes compared to total valid vote power. If above vote threshold for all, proposal is to be enacted."
                      println DEBUG "\n${FG_LGRAY}Info action doesn't have any threshold.${NC}"
                      [[ ${pages} -eq 1 ]] && waitToProceed && continue 2
                      unset hasPrev hasNext
                      println OFF "\nPage ${FG_LBLUE}${page}${NC} of ${FG_LGRAY}${pages}${NC}\n"
                      if [[ ${page} -gt 1 && ${page} -lt ${pages} ]]; then
                        hasPrev=Y; hasNext=Y
                        println OFF "[p] Previous Page | [n] Next Page | [r] Return | [d] Details"
                      elif [[ ${page} -eq 1 && ${page} -lt ${pages} ]]; then
                        hasNext=Y
                        println OFF "${FG_DGRAY}[p] Previous Page${NC} | [n] Next Page | [r] Return | [d] Details"
                      else
                        hasPrev=Y
                        println OFF "[p] Previous Page | ${FG_DGRAY}[n] Next Page${NC} | [r] Return | [d] Details"
                      fi
                      read -rsn1 key
                      case ${key} in
                        r ) continue 2 ;;
                        p ) [[ -n ${hasPrev} ]] && ((page--)) ;;
                        n ) [[ -n ${hasNext} ]] && ((page++)) ;;
                        d ) getAnswerAnyCust action_id "\nGovernance Action ID [<tx_id>#<action_idx> | CIP-129] (blank to cancel)"
                            [[ -z "${action_id}" ]] && continue
                            [[ ${action_id} = gov_action* ]] && parseGovActionId ${action_id} || IFS='#' read -r action_tx_id action_idx <<< "${action_id}"
                            ! isNumber "${action_idx}" && println ERROR "\n${FG_RED}ERROR${NC}: invalid action id!" && waitToProceed && continue
                            show_details=Y
                            ;;
                      esac
                    done
                    ;; ###################################################################
                  vote)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> CAST VOTE"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    if ! versionCheck "9.0" "${PROT_VERSION}"; then
                      println INFO "${FG_YELLOW}Not yet in Conway era, please revisit once network has crossed into Cardano governance era!${NC}"; waitToProceed && continue
                    fi
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    println DEBUG "\nSelect role to vote as"
                    select_opt "[s] SPO" "[d] DRep" "[c] Committee member" "[Esc] Cancel"
                    case $? in
                      0) vote_mode="spo"
                        selectPool "reg" "${POOL_COLDKEY_VK_FILENAME}"
                        case $? in
                          1) waitToProceed; continue ;;
                          2) continue ;;
                        esac
                        println DEBUG "\nSelect wallet to pay for transaction fee"
                        selectWallet "balance" ${WALLET_PAY_VK_FILENAME}
                        case $? in
                          1) waitToProceed; continue ;;
                          2) continue ;;
                        esac
                        getPoolID "${pool_name}"
                        pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
                        pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
                        ;;
                      1) vote_mode="drep"
                        selectWallet "none"
                        case $? in
                          1) waitToProceed; continue ;;
                          2) continue ;;
                        esac
                        drep_wallet_name="${wallet_name}"
                        getGovKeyInfo ${drep_wallet_name}
                        if [[ -z ${hash_type} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: Wallet missing governance keys!"
                          waitToProceed && continue
                        elif [[ ${hash_type} = "scriptHash" ]]; then
                          println DEBUG "\nSelect wallet to pay for transaction fee"
                          selectWallet "balance" ${WALLET_PAY_VK_FILENAME}
                          case $? in
                            1) waitToProceed; continue ;;
                            2) continue ;;
                          esac
                        fi
                        ;;
                      2) vote_mode="committee"
                        selectWallet "none" "${WALLET_GOV_CC_HOT_VK_FILENAME}"
                        case $? in
                          1) waitToProceed; continue ;;
                          2) continue ;;
                        esac
                        getGovKeyInfo ${wallet_name}
                        if [[ -z ${cc_cold_id} || -z ${cc_hot_id} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: Wallet missing governance committee keys!"
                          waitToProceed && continue
                        fi
                        ;;
                      4) continue ;;
                    esac
                    if [[ ${vote_mode} = "committee" ]]; then
                      isCommitteeMember "$(bech32 <<< ${cc_cold_id})" "$(bech32 <<< ${cc_hot_id})"
                      case $? in
                        0) : ;; # ok
                        1) println ERROR "\n${FG_RED}ERROR${NC}: selected wallet is not an active committee member!"
                           waitToProceed && continue ;;
                        2) println ERROR "\n${FG_RED}ERROR${NC}: selected wallet is an active committee member but have not authorized hot credential for voting!"
                           waitToProceed && continue ;;
                        3) println ERROR "\n${FG_RED}ERROR${NC}: selected wallet has resigned as a committee member!"
                           waitToProceed && continue ;;
                      esac
                      hash_type="keyHash"
                    elif [[ ${vote_mode} = "drep" ]]; then
                      if ! getDRepStatus ${hash_type} ${drep_hash}; then
                        println ERROR "\n${FG_RED}ERROR${NC}: wallet not registered as a DRep!"
                        waitToProceed && continue
                      fi
                      if ! getDRepVotePower ${hash_type} ${drep_hash}; then
                        println ERROR "\n${FG_RED}ERROR${NC}: selected wallet has no vote power associated with it!"
                        waitToProceed && continue
                      fi
                    fi
                    echo
                    getAnswerAnyCust action_id "Governance Action ID [<tx_id>#<action_idx> | CIP-129] (blank to cancel)"
                    [[ -z "${action_id}" ]] && continue
                    [[ ${action_id} = gov_action* ]] && parseGovActionId ${action_id} || IFS='#' read -r action_tx_id action_idx <<< "${action_id}"
                    ! isNumber "${action_idx}" && println ERROR "\n${FG_RED}ERROR${NC}: invalid action id!" && waitToProceed && continue
                    getGovActionId "${action_tx_id}" "${action_idx}"
                    getGovAction "${action_tx_id}" "${action_idx}"
                    case $? in
                      1) println ERROR "\n${FG_RED}ERROR${NC}: governance action id not found!"; waitToProceed && continue ;;
                      2) println ERROR "\n${FG_YELLOW}WARN${NC}: invalid governance action proposal anchor url or content"
                        println DEBUG "URL : ${FG_LGRAY}${proposal_url}${NC}"
                        println DEBUG "\nContinue?"
                        select_opt "[n] No" "[y] Yes"
                        case $? in
                          0) continue ;;
                          1) : ;; # do nothing
                        esac
                        ;;
                      3) println ERROR "\n${FG_YELLOW}WARN${NC}: invalid governance action proposal anchor hash"
                        println DEBUG "Action hash : ${FG_LGRAY}${proposal_hash}${NC}"
                        println DEBUG "Real hash   : ${FG_LGRAY}${proposal_meta_hash}${NC}"
                        println DEBUG "\nContinue?"
                        select_opt "[n] No" "[y] Yes"
                        case $? in
                          0) continue ;;
                          1) : ;; # do nothing
                        esac
                        ;;
                    esac
                    isAllowedToVote ${vote_mode} ${proposal_type} ${isParameterSecurityGroup}
                    case $? in
                      1) println ERROR "\n${FG_RED}ERROR${NC}: Voter of type '${vote_mode}' is not allowed to vote on an action of type '${proposal_type}'!"; waitToProceed && continue ;;
                      2) println ERROR "\n${FG_RED}ERROR${NC}: This proposal does not contain a parameter of the SecurityGroup, so voter of type '${vote_mode}' is not allowed to vote!"; waitToProceed && continue ;;
                      3) println ERROR "\n${FG_RED}ERROR${NC}: Voter of type '${vote_mode}' is not allowed to vote on an action of type '${proposal_type}' during Conway bootstrap phase (Chang-1)!"; waitToProceed && continue ;;
                    esac
                    println DEBUG "\nPrint governance action details?"
                    select_opt "[y] Yes" "[n] No"
                    case $? in
                      0) println DEBUG "\nGovernance Action Details${FG_LGRAY}"
                         jq -er <<< "${vote_action}" 2>/dev/null || echo "${vote_action}"
                         ;;
                      1) : ;; # do nothing
                    esac
                    if [[ -f "${proposal_meta_file}" ]]; then
                      println DEBUG "\nPrint anchor content?"
                      select_opt "[y] Yes" "[n] No"
                      case $? in
                        0) println DEBUG "\nGovernance Action Anchor Content${FG_LGRAY}"
                           jq -er "${proposal_meta_file}" 2>/dev/null || cat "${proposal_meta_file}"
                           ;;
                        1) : ;; # do nothing
                      esac
                    fi
                    println DEBUG "${NC}\nHow do you want to vote?"
                    select_opt "[y] Yes" "[n] No" "[a] Abstain" "[Esc] Cancel"
                    case $? in
                      0) vote_param="--yes" ;;
                      1) vote_param="--no" ;;
                      2) vote_param="--abstain" ;;
                      3) continue ;;
                    esac
                    vote_file="${TMP_DIR}/${action_tx_id}_${action_idx}_$(date '+%Y%m%d%H%M%S').vote"
                    VOTE_CMD=(
                      ${CCLI} conway governance vote create
                      ${vote_param}
                      --governance-action-tx-id "${action_tx_id}"
                      --governance-action-index "${action_idx}"
                      --out-file "${vote_file}"
                    )
                    if [[ ${vote_mode} = "spo" ]]; then
                      VOTE_CMD+=(--cold-verification-key-file "${pool_coldkey_vk_file}")
                    elif [[ ${vote_mode} = "drep" ]]; then
                      if [[ ${hash_type} = "keyHash" ]]; then
                        VOTE_CMD+=(--drep-verification-key-file "${drep_vk_file}")
                      else
                        VOTE_CMD+=(--drep-script-hash "${drep_hash}")
                      fi
                    else
                      VOTE_CMD+=(--cc-hot-verification-key-file "${cc_hot_vk_file}")
                    fi
                    println ACTION "${VOTE_CMD[*]}"
                    if ! stdout=$("${VOTE_CMD[@]}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during governance vote creation!\n${stdout}"; waitToProceed && continue
                    fi
                    getWalletBalance ${wallet_name} true true false true
                    if [[ ${base_lovelace} -le 0 ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                      println DEBUG "Funds for transaction fee needed to cast governance vote"
                      waitToProceed && continue
                    fi
                    if ! governanceVote; then
                      [[ -f ${vote_file} ]] && rm -f ${vote_file}
                      waitToProceed && continue
                    fi
                    echo
                    if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
                    echo
                    println "successfully cast vote!"
                    waitToProceed && continue
                    ;; ###################################################################
                  drep-reg)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> DREP REGISTRATION / UPDATE"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    if ! versionCheck "9.0" "${PROT_VERSION}"; then
                      println INFO "\n${FG_YELLOW}Not yet in Conway era, please revisit once network has crossed into Cardano governance era!${NC}"; waitToProceed && continue
                    fi
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    println DEBUG "\nSelect wallet"
                    selectWallet "balance"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    drep_wallet_name=${wallet_name}
                    getGovKeyInfo "${drep_wallet_name}"
                    if [[ -z ${drep_id} ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: Wallet missing governance keys, please first derive them!"
                      waitToProceed && continue
                    fi
                    getDRepStatus ${hash_type} ${drep_hash} && is_update=Y || is_update=N
                    if [[ ${hash_type} = "scriptHash" ]]; then
                      println DEBUG "\nSelect wallet to pay for transaction fee"
                      selectWallet "balance" ${WALLET_PAY_VK_FILENAME}
                      case $? in
                        1) waitToProceed; continue ;;
                        2) continue ;;
                      esac
                    fi
                    getWalletBalance ${wallet_name} true true false true
                    if [[ ${is_update} = Y && ${base_lovelace} -le 0 ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                      println DEBUG "Funds for transaction fee needed to update DRep registration"
                      waitToProceed && continue
                    elif [[ ${is_update} = N && ${base_lovelace} -le ${DREP_DEPOSIT} ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: insufficient funds in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                      println DEBUG "Funds for DRep deposit($(formatLovelace ${DREP_DEPOSIT}) ADA) + transaction fee needed to register as DRep"
                      waitToProceed && continue
                    fi
                    drep_cert_file="${WALLET_FOLDER}/${drep_wallet_name}/${WALLET_GOV_DREP_REGISTER_CERT_FILENAME}"
                    drep_meta_file="${WALLET_FOLDER}/${drep_wallet_name}/drep_meta.json"
                    unset drep_anchor_url drep_anchor_hash
                    println DEBUG "\nAdd DRep anchor URL?"
                    select_opt "[n] No" "[y] Yes"
                    case $? in
                      0) unset drep_meta_file ;;
                      1) getAnswerAnyCust drep_anchor_url "Enter DRep's anchor URL"
                        if [[ ! "${drep_anchor_url}" =~ https?://.* || ${#drep_anchor_url} -gt 64 ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
                          waitToProceed && continue
                        fi
                        if curl -sL -f -m ${CURL_TIMEOUT} -o "${drep_meta_file}" ${drep_anchor_url} && jq -er . "${drep_meta_file}" &>/dev/null; then
                          println ACTION "${CCLI} conway governance drep metadata-hash --drep-metadata-file ${drep_meta_file}"
                          if ! drep_anchor_hash=$(${CCLI} conway governance drep metadata-hash --drep-metadata-file "${drep_meta_file}" 2>&1); then
                            println ERROR "\n${FG_RED}ERROR${NC}: failure during governance drep metadata hash creation!\n${drep_anchor_hash}"; waitToProceed && continue
                          fi
                        else
                          println ERROR "\n${FG_RED}ERROR${NC}: failed to download anchor file or invalid json format"; waitToProceed && continue
                        fi
                        println DEBUG "\nDRep anchor metadata:"
                        jq -r . "${drep_meta_file}"
                        println DEBUG "\nDRep anchor metadata hash: ${FG_LGRAY}${drep_anchor_hash}${NC}"
                        ;;
                    esac
                    if [[ ${hash_type} = "scriptHash" ]]; then
                      drep_reg_param=(--drep-script-hash "${drep_hash}")
                    else
                      drep_reg_param=(--drep-verification-key-file "${drep_vk_file}")
                    fi
                    if [[ ${is_update} = N ]]; then
                      # registration
                      DREP_REG_CMD=(
                        ${CCLI} conway governance drep registration-certificate
                        "${drep_reg_param[@]}"
                        --key-reg-deposit-amt ${DREP_DEPOSIT}
                        --out-file "${drep_cert_file}"
                      )
                    else
                      # update
                      DREP_REG_CMD=(
                        ${CCLI} conway governance drep update-certificate
                        "${drep_reg_param[@]}"
                        --out-file "${drep_cert_file}"
                      )
                    fi
                    if [[ -n ${drep_anchor_url} ]]; then
                      DREP_REG_CMD+=(
                        --drep-metadata-url ${drep_anchor_url}
                        --drep-metadata-hash "${drep_anchor_hash}"
                      )
                    fi
                    println ACTION "${DREP_REG_CMD[*]}"
                    if ! stdout=$("${DREP_REG_CMD[@]}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during DRep registration certificate creation!\n${stdout}"; waitToProceed && continue
                    fi
                    if ! registerDRep; then
                      [[ -f ${drep_cert_file} ]] && rm -f ${drep_cert_file}
                      waitToProceed && continue
                    fi
                    echo
                    if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
                    echo
                    if [[ ${is_update} = N ]]; then
                      println "${FG_GREEN}${drep_wallet_name}${NC} successfully registered as DRep on chain!"
                      println "DRep deposit : ${FG_LBLUE}$(formatLovelace ${DREP_DEPOSIT})${NC} ADA (returned when retired)"
                      println DEBUG "\n${FG_YELLOW}NOTE:${NC} A DRep registration does not automatically delegate own wallet stake power to self!"
                    else
                      println "${FG_GREEN}${drep_wallet_name}${NC} DRep details updated!"
                    fi
                    waitToProceed && continue
                    ;; ###################################################################
                  drep-ret)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> DREP RETIRE"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    if ! versionCheck "9.0" "${PROT_VERSION}"; then
                      println INFO "\n${FG_YELLOW}Not yet in Conway era, please revisit once network has crossed into Cardano governance era!${NC}"; waitToProceed && continue
                    fi
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    println DEBUG "\nSelect wallet (derive governance keys if missing)"
                    selectWallet "balance"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    drep_wallet_name=${wallet_name}
                    getGovKeyInfo ${drep_wallet_name}
                    if [[ -z ${drep_id} ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: Wallet missing governance keys!"
                      waitToProceed && continue
                    fi
                    if ! getDRepStatus ${hash_type} ${drep_hash}; then
                      println ERROR "\n${FG_RED}ERROR${NC}: Wallet not registered as a DRep, unable to retire!"
                      waitToProceed && continue
                    fi
                    drep_cert_file="${WALLET_FOLDER}/${drep_wallet_name}/${WALLET_GOV_DREP_RETIRE_CERT_FILENAME}"
                    if [[ ${hash_type} = "scriptHash" ]]; then
                      drep_ret_param=(--drep-script-hash "${drep_hash}")
                    else
                      drep_ret_param=(--drep-verification-key-file "${drep_vk_file}")
                    fi
                    DREP_RET_CMD=(
                      ${CCLI} conway governance drep retirement-certificate
                      "${drep_ret_param[@]}"
                      --deposit-amt ${drep_deposit_amt}
                      --out-file "${drep_cert_file}"
                    )
                    println ACTION "${DREP_RET_CMD[*]}"
                    if ! stdout=$("${DREP_RET_CMD[@]}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during DRep retirement certificate creation!\n${stdout}"; waitToProceed && continue
                    fi
                    if [[ ${hash_type} = "scriptHash" ]]; then
                      println DEBUG "\nSelect wallet to pay for the transaction fee and that gets the returned DRep deposit"
                      selectWallet "balance" ${WALLET_PAY_VK_FILENAME}
                      case $? in
                        1) waitToProceed; continue ;;
                        2) continue ;;
                      esac
                    fi
                    getWalletBalance ${wallet_name} true true false true
                    if [[ ${base_lovelace} -le 0 ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                      println DEBUG "Funds for transaction fee needed to retire as a DRep"
                      waitToProceed && continue
                    fi
                    if ! retireDRep; then
                      [[ -f ${drep_cert_file} ]] && rm -f ${drep_cert_file}
                      waitToProceed && continue
                    fi
                    echo
                    if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
                    echo
                    println "${FG_GREEN}${drep_wallet_name}${NC} successfully retired as DRep!"
                    println "DRep deposit : ${FG_LBLUE}$(formatLovelace ${drep_deposit_amt})${NC} ADA returned"
                    waitToProceed && continue
                    ;; ###################################################################
                  create-ms-drep)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> MULTISIG DREP"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    createNewWallet || continue
                    ms_wallet_name="${wallet_name}"
                    # Wallet key filenames
                    ms_drep_script_file="${WALLET_FOLDER}/${ms_wallet_name}/${WALLET_GOV_DREP_SCRIPT_FILENAME}"
                    if [[ $(find "${WALLET_FOLDER}/${ms_wallet_name}" -type f -print0 | wc -c) -gt 0 ]]; then
                      println "${FG_RED}WARN${NC}: A wallet ${FG_GREEN}${ms_wallet_name}${NC} already exists"
                      println "      Choose another name or delete the existing one"
                      waitToProceed && continue
                    fi
                    # drep key hashes as keys to associative array to act as a set
                    declare -gA key_hashes=()
                    println OFF "Select wallet(s) / DRep IDs to include in MultiSig DRep"
                    println OFF "${FG_YELLOW}!${NC} Please use 1854H (MultiSig) derived keys according to CIP-1854!"
                    println OFF "${FG_YELLOW}!${NC} Only wallets with these keys will be listed, use 'Derive Keys' option to generate them."
                    echo
                    selected_wallets=()
                    while true; do
                      println DEBUG "Select wallet or manually enter DRep ID?"
                      select_opt "[w] Wallet" "[i] DRep (ID or hash)" "[d] I'm done" "[Esc] Cancel"
                      case $? in
                        0) selectWallet "none" "${selected_wallets[@]}" "${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
                          case $? in
                            1) waitToProceed; continue ;;
                            2) continue ;;
                          esac
                          getWalletType ${wallet_name}
                          if [[ $? -eq 0 ]]; then
                            println ERROR "\n${FG_YELLOW}HW wallets currently not supported in a MultiSig DRep, please select only normal mnemonic or cli wallets${NC}" && waitToProceed && continue
                          fi
                          getGovKeyInfo ${wallet_name}
                          [[ -z ${ms_drep_id} || ${ms_drep_id} != drep* ]] && println ERROR "\n${FG_RED}ERROR${NC}: invalid wallet, MultiSig DRep keys not found!" && waitToProceed && continue
                          key_hashes["${ms_drep_hash}"]=1
                          selected_wallets+=("${wallet_name}")
                          ;;
                        1) getAnswerAnyCust drep_id "MultiSig DRep ID [CIP-105 or CIP-129] (blank to cancel)"
                          [[ -z "${drep_id}" ]] && continue
                          parseDRepId "${drep_id}"
                          [[ -z ${drep_id} ]] && println ERROR "\n${FG_RED}ERROR${NC}: invalid DRep ID entered!" && waitToProceed && continue
                          key_hashes[${drep_hash})]=1
                          ;;
                        2) break ;;
                        3) safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; continue 2 ;;
                      esac
                      println DEBUG "\nMultiSig size: ${#key_hashes[@]} - Add more wallets / DRep IDs to MultiSig?"
                      select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                      case $? in
                        0) break ;;
                        1) : ;;
                        2) safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; continue 2 ;;
                      esac
                    done
                    if [[ ${#key_hashes[@]} -eq 0 ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: no signers added, please add at least one"; safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; waitToProceed; continue
                    fi
                    println DEBUG "\n${#key_hashes[@]} wallets / DRep IDs added to MultiSig, how many are required to witness the transaction?"
                    getAnswerAnyCust required_sig_cnt "Number of Required signatures"
                    if ! isNumber ${required_sig_cnt} || [[ ${required_sig_cnt} -lt 1 || ${required_sig_cnt} -gt ${#key_hashes[@]} ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: invalid signature count entered, must be above 1 and max ${#key_hashes[@]}"; safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; waitToProceed; continue
                    fi
                    # build MultiSig script
                    drep_script=$(jq -n --argjson req_sig "${required_sig_cnt}" '{type:"atLeast",required:$req_sig,scripts:[]}')
                    for sig in "${!key_hashes[@]}"; do
                      drep_script=$(jq --arg sig "${sig}" '.scripts += [{type:"sig",keyHash:$sig}]' <<< "${drep_script}")
                    done
                    if ! stdout=$(jq -e . <<< "${drep_script}" > "${ms_drep_script_file}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during DRep script file creation!\n${stdout}"; safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; waitToProceed && continue
                    fi
                    chmod 600 "${WALLET_FOLDER}/${ms_wallet_name}/"*
                    getGovKeyInfo ${ms_wallet_name}
                    getDRepIds scriptHash ${ms_drep_hash}
                    echo
                    println "New MultiSig DRep : ${FG_GREEN}${ms_wallet_name}${NC}"
                    println "DRep ID           : CIP-105 => ${FG_LGRAY}${drep_id}${NC}"
                    println "                  : CIP-129 => ${FG_LGRAY}${drep_id_cip129}${NC}"
                    println "DRep Script Hash  : ${FG_LGRAY}${ms_drep_hash}${NC}"
                    println DEBUG "\nNote that this is not a normal wallet and can only be used to vote as a DRep coalition."
                    waitToProceed && continue
                    ;; ###################################################################
                  derive-gov-keys)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> DERIVE"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    println DEBUG "Select wallet to derive governance keys for (only wallets with missing keys shown)"
                    selectWallet "non-gov"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    getWalletType ${wallet_name}
                    case $? in
                      0) # Hardware wallet
                        if ! cmdAvailable "cardano-hw-cli" &>/dev/null; then
                          println ERROR "${FG_RED}ERROR${NC}: cardano-hw-cli not found in path or executable permission not set."
                          println ERROR "Please run '${FG_YELLOW}guild-deploy.sh -s w${NC}' to add hardware wallet support and install Vaccumlabs cardano-hw-cli, '${FG_YELLOW}guild-deploy.sh -h${NC}' shows all available options"
                          waitToProceed && continue
                        fi
                        if ! HWCLIversionCheck; then waitToProceed && continue; fi
                        drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_VK_FILENAME}"
                        drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_HW_DREP_SK_FILENAME}"
                        cc_cold_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_COLD_VK_FILENAME}"
                        cc_cold_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_HW_CC_COLD_SK_FILENAME}"
                        cc_hot_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_HOT_VK_FILENAME}"
                        cc_hot_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_HW_CC_HOT_SK_FILENAME}"
                        ms_drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_HW_DREP_SK_FILENAME}"
                        ms_drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
                        if [[ -f ${drep_sk_file} || -f ${cc_cold_sk_file} || -f ${cc_hot_sk_file} || -f ${ms_drep_sk_file} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: some governance signing keys already exist!\n${stdout}"; waitToProceed && continue
                        fi
                        derivation_path_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DERIVATION_PATH_FILENAME}"
                        if ! getSavedDerivationPath "${derivation_path_file}"; then
                          getCustomDerivationPath || continue
                          echo "1852H/1815H/${acct_idx}H/x/${key_idx}" > "${derivation_path_file}"
                        fi
                        if ! unlockHWDevice "extract ${FG_LGRAY}governance keys${NC}"; then waitToProceed && continue; fi
                        HW_CLI_CMD=(
                          cardano-hw-cli address key-gen
                          --path 1852H/1815H/${acct_idx}H/3/${key_idx}
                          --path 1852H/1815H/${acct_idx}H/4/${key_idx}
                          --path 1852H/1815H/${acct_idx}H/5/${key_idx}
                          --verification-key-file "${drep_vk_file}"
                          --verification-key-file "${cc_cold_vk_file}"
                          --verification-key-file "${cc_hot_vk_file}"
                          --hw-signing-file "${drep_sk_file}"
                          --hw-signing-file "${cc_cold_sk_file}"
                          --hw-signing-file "${cc_hot_sk_file}"
                        )
                        println ACTION "${HW_CLI_CMD[*]}"
                        if ! stdout=$("${HW_CLI_CMD[@]}" 2>&1); then
                          println ERROR "\n${FG_RED}ERROR${NC}: failure during governance key extraction!\n${stdout}"; waitToProceed && continue
                        fi
                        cp "${drep_sk_file}" "${ms_drep_sk_file}"
                        cp "${drep_vk_file}" "${ms_drep_vk_file}"
                        jq '.description = "Delegate Representative Hardware Verification Key"' "${drep_vk_file}" > "${TMP_DIR}/$(basename "${drep_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${drep_vk_file}").tmp" "${drep_vk_file}"
                        jq '.description = "Constitutional Committee Cold Hardware Verification Key"' "${cc_cold_vk_file}" > "${TMP_DIR}/$(basename "${cc_cold_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${cc_cold_vk_file}").tmp" "${cc_cold_vk_file}"
                        jq '.description = "Constitutional Committee Hot Hardware Verification Key"' "${cc_hot_sk_file}" > "${TMP_DIR}/$(basename "${cc_hot_sk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${cc_hot_sk_file}").tmp" "${cc_hot_sk_file}"
                        jq '.description = "MultiSig Delegate Representative Hardware Verification Key"' "${ms_drep_vk_file}" > "${TMP_DIR}/$(basename "${ms_drep_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${ms_drep_vk_file}").tmp" "${ms_drep_vk_file}"
                        ;;
                      5) println ERROR "\n${FG_RED}ERROR${NC}: MultiSig wallets not supported as DRep wallet, only vote delegation supported!\n${stdout}"; waitToProceed && continue ;;
                      *)
                        drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_VK_FILENAME}"
                        drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_SK_FILENAME}"
                        cc_cold_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_COLD_VK_FILENAME}"
                        cc_cold_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_COLD_SK_FILENAME}"
                        cc_hot_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_HOT_VK_FILENAME}"
                        cc_hot_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_HOT_SK_FILENAME}"
                        ms_drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
                        ms_drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_SK_FILENAME}"
                        if [[ -f ${drep_sk_file} || -f ${cc_cold_sk_file} || -f ${cc_hot_sk_file} || -f ${ms_drep_sk_file} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: some governance signing keys already exist!\n${stdout}"; waitToProceed && continue
                        fi
                        println DEBUG "Is selected wallet a CLI generated wallet or derived from mnemonic?"
                        select_opt "[c] CLI" "[m] Mnemonic"
                        case $? in
                          0) println ACTION "${CCLI} conway governance drep key-gen --verification-key-file ${drep_vk_file} --signing-key-file ${drep_sk_file}"
                            if ! stdout=$(${CCLI} conway governance drep key-gen --verification-key-file "${drep_vk_file}" --signing-key-file "${drep_sk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during governance drep key creation!\n${stdout}"; waitToProceed && continue
                            fi
                            println ACTION "${CCLI} conway governance committee key-gen-cold --cold-verification-key-file ${cc_cold_vk_file} --cold-signing-key-file ${cc_cold_sk_file}"
                            if ! stdout=$(${CCLI} conway governance committee key-gen-cold --cold-verification-key-file "${cc_cold_vk_file}" --cold-signing-key-file "${cc_cold_sk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during governance committee cold key creation!\n${stdout}"; waitToProceed && continue
                            fi
                            println ACTION "${CCLI} conway governance committee key-gen-hot --verification-key-file ${cc_hot_vk_file} --signing-key-file ${cc_hot_sk_file}"
                            if ! stdout=$(${CCLI} conway governance committee key-gen-hot --verification-key-file "${cc_hot_vk_file}" --signing-key-file "${cc_hot_sk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during governance committee hot key creation!\n${stdout}"; waitToProceed && continue
                            fi
                            println ACTION "${CCLI} conway governance drep key-gen --verification-key-file ${ms_drep_vk_file} --signing-key-file ${ms_drep_sk_file}"
                            if ! stdout=$(${CCLI} conway governance drep key-gen --verification-key-file "${ms_drep_vk_file}" --signing-key-file "${ms_drep_sk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig governance drep key creation!\n${stdout}"; waitToProceed && continue
                            fi
                            ;;
                          1) if ! cmdAvailable "bech32" &>/dev/null || \
                              ! cmdAvailable "cardano-address" &>/dev/null; then
                              println ERROR "${FG_RED}ERROR${NC}: bech32 and/or cardano-address not found in '\$PATH'"
                              println ERROR "Please run updated guild-deploy.sh and re-build/re-download cardano-node"
                              waitToProceed && continue
                            fi
                            getAnswerAnyCust mnemonic false "24 or 15 word mnemonic(space separated)"
                            echo
                            IFS=" " read -r -a words <<< "${mnemonic}"
                            if [[ ${#words[@]} -ne 24 ]] && [[ ${#words[@]} -ne 15 ]]; then
                              println ERROR "${FG_RED}ERROR${NC}: 24 or 15 words expected, found ${FG_RED}${#words[@]}${NC}"
                              unset mnemonic; unset words
                              waitToProceed && continue
                            fi
                            derivation_path_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DERIVATION_PATH_FILENAME}"
                            if ! getSavedDerivationPath "${derivation_path_file}"; then
                              getCustomDerivationPath || continue
                              echo "1852H/1815H/${acct_idx}H/x/${key_idx}" > "${derivation_path_file}"
                            fi
                            caddr_v="$(cardano-address -v | awk '{print $1}')"
                            [[ "${caddr_v}" == 3* ]] && caddr_arg="--with-chain-code" || caddr_arg=""
                            if ! root_prv=$(cardano-address key from-recovery-phrase Shelley <<< ${mnemonic}); then
                              unset mnemonic; unset words
                              waitToProceed && continue
                            fi
                            unset mnemonic; unset words
                            drep_xprv=$(cardano-address key child 1852H/1815H/${acct_idx}H/3/${key_idx} <<< ${root_prv})
                            cc_cold_xprv=$(cardano-address key child 1852H/1815H/${acct_idx}H/4/${key_idx} <<< ${root_prv})
                            cc_hot_xprv=$(cardano-address key child 1852H/1815H/${acct_idx}H/5/${key_idx} <<< ${root_prv})
                            ms_drep_xprv=$(cardano-address key child 1854H/1815H/${acct_idx}H/3/${key_idx} <<< ${root_prv})
                            drep_xpub=$(cardano-address key public ${caddr_arg} <<< ${drep_xprv})
                            cc_cold_xpub=$(cardano-address key public ${caddr_arg} <<< ${cc_cold_xprv})
                            cc_hot_xpub=$(cardano-address key public ${caddr_arg} <<< ${cc_hot_xprv})
                            ms_drep_xpub=$(cardano-address key public ${caddr_arg} <<< ${ms_drep_xprv})
                            drep_es_key=$(bech32 <<< ${drep_xprv} | cut -b -128)$(bech32 <<< ${drep_xpub})
                            cc_cold_es_key=$(bech32 <<< ${cc_cold_xprv} | cut -b -128)$(bech32 <<< ${cc_cold_xpub})
                            cc_hot_es_key=$(bech32 <<< ${cc_hot_xprv} | cut -b -128)$(bech32 <<< ${cc_hot_xpub})
                            ms_drep_es_key=$(bech32 <<< ${ms_drep_xprv} | cut -b -128)$(bech32 <<< ${ms_drep_xpub})
                            cat <<-EOF > "${drep_sk_file}"
															{
																	"type": "DRepExtendedSigningKey_ed25519_bip32",
																	"description": "Delegate Representative Signing Key",
																	"cborHex": "5880${drep_es_key}"
															}
															EOF
                            cat <<-EOF > "${cc_cold_sk_file}"
															{
																	"type": "ConstitutionalCommitteeColdExtendedSigningKey_ed25519_bip32",
																	"description": "Constitutional Committee Cold Signing Key",
																	"cborHex": "5880${cc_cold_es_key}"
															}
															EOF
                            cat <<-EOF > "${cc_hot_sk_file}"
															{
																	"type": "ConstitutionalCommitteeHotExtendedSigningKey_ed25519_bip32",
																	"description": "Constitutional Committee Hot Signing Key",
																	"cborHex": "5880${cc_hot_es_key}"
															}
															EOF
                            cat <<-EOF > "${ms_drep_sk_file}"
															{
																	"type": "DRepExtendedSigningKey_ed25519_bip32",
																	"description": "MultiSig Delegate Representative Signing Key",
																	"cborHex": "5880${drep_es_key}"
															}
															EOF
                            println ACTION "${CCLI} conway key verification-key --signing-key-file ${drep_sk_file} --verification-key-file ${TMP_DIR}/drep.evkey"
                            if ! stdout=$(${CCLI} conway key verification-key --signing-key-file "${drep_sk_file}" --verification-key-file "${TMP_DIR}/drep.evkey" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during drep extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} conway key verification-key --signing-key-file ${cc_cold_sk_file} --verification-key-file ${TMP_DIR}/cc-cold.evkey"
                            if ! stdout=$(${CCLI} conway key verification-key --signing-key-file "${cc_cold_sk_file}" --verification-key-file "${TMP_DIR}/cc-cold.evkey" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during cc-cold extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} conway key verification-key --signing-key-file ${cc_hot_sk_file} --verification-key-file ${TMP_DIR}/cc-hot.evkey"
                            if ! stdout=$(${CCLI} conway key verification-key --signing-key-file "${cc_hot_sk_file}" --verification-key-file "${TMP_DIR}/cc-hot.evkey" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during cc-hot extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} conway key verification-key --signing-key-file ${ms_drep_sk_file} --verification-key-file ${TMP_DIR}/ms_drep.evkey"
                            if ! stdout=$(${CCLI} conway key verification-key --signing-key-file "${ms_drep_sk_file}" --verification-key-file "${TMP_DIR}/ms_drep.evkey" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig drep extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} conway key non-extended-key --extended-verification-key-file ${TMP_DIR}/drep.evkey --verification-key-file ${drep_vk_file}"
                            if ! stdout=$(${CCLI} conway key non-extended-key --extended-verification-key-file "${TMP_DIR}/drep.evkey" --verification-key-file "${drep_vk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during drep verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} conway key non-extended-key --extended-verification-key-file ${TMP_DIR}/cc-cold.evkey --verification-key-file ${cc_cold_vk_file}"
                            if ! stdout=$(${CCLI} conway key non-extended-key --extended-verification-key-file "${TMP_DIR}/cc-cold.evkey" --verification-key-file "${cc_cold_vk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during cc-cold verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} conway key non-extended-key --extended-verification-key-file ${TMP_DIR}/cc-hot.evkey --verification-key-file ${cc_hot_vk_file}"
                            if ! stdout=$(${CCLI} conway key non-extended-key --extended-verification-key-file "${TMP_DIR}/cc-hot.evkey" --verification-key-file "${cc_hot_vk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during cc-hot verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} conway key non-extended-key --extended-verification-key-file ${TMP_DIR}/ms_drep.evkey --verification-key-file ${ms_drep_vk_file}"
                            if ! stdout=$(${CCLI} conway key non-extended-key --extended-verification-key-file "${TMP_DIR}/ms_drep.evkey" --verification-key-file "${ms_drep_vk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig drep verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            ;;
                        esac
                        ;;
                    esac
                    chmod 600 "${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}"*
                    echo
                    getGovKeyInfo ${wallet_name}
                    println "Wallet            : ${FG_GREEN}${wallet_name}${NC}"
                    println "DRep ID           : CIP-105 => ${FG_LGRAY}${drep_id}${NC}"
                    println "                  : CIP-129 => ${FG_LGRAY}${drep_id_cip129}${NC}"
                    println "Committee Cold ID : CIP-105 => ${FG_LGRAY}${cc_cold_id}${NC}"
                    println "                  : CIP-129 => ${FG_LGRAY}${cc_cold_id_cip129}${NC}"
                    println "Committee Hot ID  : CIP-105 => ${FG_LGRAY}${cc_hot_id}${NC}"
                    println "                  : CIP-129 => ${FG_LGRAY}${cc_hot_id_cip129}${NC}"
                    waitToProceed && continue
                    ;; ###################################################################
                esac # vote sub OPERATION
              done # vote loop
              ;; ###################################################################
            catalyst)
              while true; do # Catalyst loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> VOTE >> CATALYST"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Catalyst\n"\
                  " ) Register    - register wallet for Catalyst"\
                  " ) Display QR  - show QR code from previous Catalyst registration"\
                  " ) Verify      - check registration status for own or external vote key"\
                  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select Catalyst Operation\n"
                select_opt "[r] Registration" "[q] Display QR" "[v] Verify" "[b] Back" "[h] Home"
                case $? in
                  0) SUBCOMMAND="catalyst_reg" ;;
                  1) SUBCOMMAND="catalyst_qr" ;;
                  2) SUBCOMMAND="catalyst_verify" ;;
                  3) break ;;
                  4) break 2 ;;
                esac
                case $SUBCOMMAND in
                  catalyst_reg)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> CATALYST >> REGISTER"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    println DEBUG "Select wallet to register for Catalyst"
                    unset isHWwallet
                    selectWallet "balance"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    getWalletType ${wallet_name}
                    case $? in
                      0) isHWwallet=true ;;
                      2) [[ ${op_mode} = "online" ]] && println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                      3) [[ ${op_mode} = "online" ]] && println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                    esac
                    if ! isWalletRegistered ${wallet_name}; then
                      println ERROR "\n${FG_RED}ERROR${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not a registered wallet on chain, please register/delegate it before Catalyst registration."
                      waitToProceed && continue
                    fi
                    getWalletBalance ${wallet_name} true true true true
                    if [[ ${base_lovelace} -gt 0 ]]; then
                      addr="${base_addr}"
                      lovelace=${base_lovelace}
                      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                        println DEBUG "\n$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                      fi
                    else
                      println ERROR "\n${FG_RED}ERROR${NC}: no base funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                      waitToProceed && continue
                    fi
                    getBaseAddress ${wallet_name}
                    download_catalyst_toolbox || continue
                    metafile="${TMP_DIR}/catalyst_reg_metadata_$(printf '%(%s)T\n' -1).cbor"
                    metatype="cbor"
                    if ! cmdAvailable "cardano-signer" &>/dev/null; then
                      println ERROR "\n${FG_RED}ERROR${NC}: prerequisite tool cardano-signer missing or not executable, please install using ${FG_LGRAY}guild-deploy.sh${NC}"
                      waitToProceed && continue
                    fi
                    catalyst_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_CATALYST_SK_FILENAME}"
                    catalyst_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_CATALYST_VK_FILENAME}"
                    catalyst_qr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_CATALYST_QR_FILENAME}"
                    if [[ ! -f "${catalyst_vk_file}" && ! -f "${catalyst_sk_file}" ]]; then
                      println ACTION "cardano-signer keygen --cip36 --out-skey ${catalyst_sk_file} --out-vkey ${catalyst_vk_file}"
                      if ! stdout=$(cardano-signer keygen --cip36 --out-skey "${catalyst_sk_file}" --out-vkey "${catalyst_vk_file}" 2>&1); then
                        println ERROR "\n${FG_RED}ERROR${NC}: failure during catalyst key creation!\n${stdout}"; waitToProceed && continue
                      fi
                    fi
                    generateCatalystBech32 ${wallet_name} || continue
                    if [[ -f "${catalyst_qr_file}" ]]; then
                      println "A previous registration found, continue with registration and overwrite?"
                      select_opt "[y] Yes" "[n] No"
                      case $? in
                        0) : ;; # do nothing
                        1) waitToProceed && continue ;;
                      esac
                    fi
                    if [[ -z ${isHWwallet} ]]; then
                      catalyst_meta_cmd=(
                        cardano-signer sign --cip36
                        ${NETWORK_IDENTIFIER}
                        --payment-address "${base_addr}"
                        --vote-public-key "${catalyst_vk_file}"
                        --secret-key "${stake_sk_file}"
                        --out-cbor "${metafile}"
                      )
                    else
                      # HW Wallet
                      if ! cmdAvailable "cardano-hw-cli" &>/dev/null; then
                        println ERROR "\n${FG_RED}ERROR${NC}: prerequisite tool cardano-hw-cli missing or not executable, please install using ${FG_LGRAY}guild-deploy.sh${NC}"
                        waitToProceed && continue
                      fi
                      if ! HWCLIversionCheck; then waitToProceed && continue; fi
                      if ! unlockHWDevice "create Catalyst vote metadata"; then waitToProceed && continue; fi
                      current_slot=$(getSlotTipRef)
                      catalyst_meta_cmd=(
                        cardano-hw-cli vote registration-metadata
                        ${NETWORK_IDENTIFIER}
                        --vote-public-key-file "${catalyst_vk_file}"
                        --payment-address "${base_addr}"
                        --stake-signing-key-hwsfile "${stake_sk_file}"
                        --nonce ${current_slot}
                        --payment-address-signing-key-hwsfile "${payment_sk_file}"
                        --metadata-cbor-out-file "${metafile}"
                      )
                    fi
                    println ACTION "${catalyst_meta_cmd[*]}"
                    if ! stdout=$("${catalyst_meta_cmd[@]}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during catalyst metadata creation!\n${stdout}"; waitToProceed && continue
                    fi
                    if ! sendMetadata; then
                      waitToProceed && continue
                    fi
                    echo
                    if ! verifyTx ${addr}; then waitToProceed && continue; fi
                    echo
                    println "Catalyst registration metadata successfully posted on-chain"
                    while true; do
                      echo
                      getAnswerAnyCust pin_enter "Enter a 4-Digit PIN"
                      if ! isNumber ${pin_enter} || [[ ${#pin_enter} -ne 4 ]]; then
                        println ERROR "\n${FG_RED}ERROR${NC}: invalid PIN entered! Please try again"
                        continue
                      fi
                      break
                    done
                    # save QR
                    catalyst_qr_cmd=(
                      catalyst-toolbox qr-code encode
                      --pin ${pin_enter}
                      --input "${catalyst_sk_file_bech32}"
                      --output "${catalyst_qr_file}"
                      --opts img
                    )
                    println ACTION "${catalyst_qr_cmd[*]}"
                    if ! stdout=$("${catalyst_qr_cmd[@]}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during catalyst QR code creation!\n${stdout}"; waitToProceed && continue
                    fi
                    # print QR
                    println DEBUG "QR Code image generated: ${catalyst_qr_file}"
                    catalyst_qr_cmd=(
                      catalyst-toolbox qr-code encode
                      --pin ${pin_enter}
                      --input "${catalyst_sk_file_bech32}"
                      --opts img
                    )
                    println ACTION "${catalyst_qr_cmd[*]}"
                    "${catalyst_qr_cmd[@]}"
                    println DEBUG "\nScan QR code using Catalyst app on mobile device"
                    println DEBUG "iOS:     https://apps.apple.com/in/app/catalyst-voting/id1517473397"
                    println DEBUG "Android: https://play.google.com/store/apps/details?id=io.iohk.vitvoting"
                    println DEBUG "\nCardano Catalyst Telegram Announcements Channel: https://t.me/cardanocatalyst"
                    waitToProceed && continue
                    ;; ###################################################################
                  catalyst_qr)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> CATALYST >> QR CODE"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    println DEBUG "Select a Catalyst registered wallet"
                    selectWallet "none" "${WALLET_CATALYST_SK_FILENAME}"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    download_catalyst_toolbox || continue
                    while true; do
                      echo
                      getAnswerAnyCust pin_enter "Enter 4-Digit PIN"
                      if ! isNumber ${pin_enter} || [[ ${#pin_enter} -ne 4 ]]; then
                        println ERROR "\n${FG_RED}ERROR${NC}: invalid PIN entered! Please try again"
                        continue
                      fi
                      break
                    done
                    catalyst_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_CATALYST_SK_FILENAME}"
                    catalyst_qr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_CATALYST_QR_FILENAME}"
                    generateCatalystBech32 ${wallet_name} || continue
                    unset save_catalyst_qr
                    if [[ -f "${catalyst_qr_file}" ]]; then
                      catalyst_qr_cmd=(
                        catalyst-toolbox qr-code verify
                        --stop-at-fail
                        --pin ${pin_enter}
                        --file "${catalyst_qr_file}"
                        --opts img
                      )
                      println ACTION "${catalyst_qr_cmd[*]}"
                      if ! "${catalyst_qr_cmd[@]}" &>/dev/null; then
                        println "PIN code invalid, overwrite existing QR code with updated PIN code?"
                        select_opt "[y] Yes" "[n] No (return)" "[c] Continue (display QR code)"
                        case $? in
                          0) save_catalyst_qr=true ;;
                          1) continue ;;
                          2) : ;;
                        esac
                      fi
                    else
                      save_catalyst_qr=true
                    fi
                    if [[ ${save_catalyst_qr} = true ]]; then
                      catalyst_qr_cmd=(
                        catalyst-toolbox qr-code encode
                        --pin ${pin_enter}
                        --input "${catalyst_sk_file_bech32}"
                        --output "${catalyst_qr_file}"
                        --opts img
                      )
                      println ACTION "${catalyst_qr_cmd[*]}"
                      if ! stdout=$("${catalyst_qr_cmd[@]}" 2>&1); then
                        println ERROR "\n${FG_RED}ERROR${NC}: failure during catalyst QR code creation!\n${stdout}"; waitToProceed && continue
                      fi
                    fi
                    catalyst_qr_cmd=(
                      catalyst-toolbox qr-code encode
                      --pin ${pin_enter}
                      --input "${catalyst_sk_file_bech32}"
                      --opts img
                    )
                    println ACTION "${catalyst_qr_cmd[*]}"
                    "${catalyst_qr_cmd[@]}"
                    println DEBUG "\nScan QR code using Catalyst app on mobile device"
                    println DEBUG "iOS:     https://apps.apple.com/in/app/catalyst-voting/id1517473397"
                    println DEBUG "Android: https://play.google.com/store/apps/details?id=io.iohk.vitvoting"
                    println DEBUG "\nCardano Catalyst Telegram Announcements Channel: https://t.me/cardanocatalyst"
                    waitToProceed && continue
                    ;; ###################################################################
                  catalyst_verify)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> CATALYST >> VERIFY"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    fi
                    if [[ ${NWMAGIC} != "764824073" ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: Catalyst registration verification only available for Mainnet at this time!"
                      waitToProceed && continue
                    fi
                    println DEBUG "Select wallet or enter vote public key?"
                    select_opt "[w] Wallet" "[p] Vote public key"
                    case $? in
                      0) println DEBUG "\nSelect a Catalyst registered wallet"
                         selectWallet "none" "${WALLET_CATALYST_VK_FILENAME}"
                         case $? in
                           1) waitToProceed; continue ;;
                           2) continue ;;
                         esac
                         catalyst_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_CATALYST_VK_FILENAME}"
                         vote_key_hex="$(jq -r .cborHex "${catalyst_vk_file}" | cut -c 5-)"
                        ;;
                      1) getAnswerAnyCust vote_key_hex "Enter public key"
                         if [[ ${#vote_key_hex} -ne 64 ]]; then
                           println ERROR "\n${FG_RED}ERROR${NC}: invalid pub key, expected 64 characters! Supply public key in hex format without prefix (5820 or 0x)"; waitToProceed && continue
                         fi
                        ;;
                    esac
                    voter_status_url="${CATALYST_API}/registration/voter/0x${vote_key_hex}?with_delegators=true"
                    println ACTION "curl -sSL -m ${CURL_TIMEOUT} -f -H \"Content-Type: application/json\" ${voter_status_url}"
                    if ! catalyst_status=$(curl -sSL -m ${CURL_TIMEOUT} -f -H "Content-Type: application/json" "${voter_status_url}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during Catalyst verification query!\n${catalyst_status}"; waitToProceed && continue
                    fi
                    echo
                    if [[ ${catalyst_status} = *error\":* ]]; then
                      println DEBUG "Status:           ${FG_YELLOW}$(jq -r .error <<< "${catalyst_status}")${NC}"
                      waitToProceed && continue
                    fi
                    while IFS=',' read -r _last_updated _final _voting_power _delegations_count _delegator_addresses; do
                      final_color=$([[ ${_final} = false ]] && echo "${FG_YELLOW}" || echo "${FG_GREEN}")
                      println DEBUG "Status:           ${FG_GREEN}registered${NC}"
                      println DEBUG "Last updated:     ${FG_LGRAY}$(printf '%(%F %T %Z)T' "$(date -d"${_last_updated}" +%s)")${NC}"
                      println DEBUG "Is Finalized:     ${final_color}${_final}${NC}"
                      println DEBUG "Voting power:     ${FG_LBLUE}$(formatLovelace ${_voting_power})${NC}"
                      println DEBUG "Delegation count: ${FG_LBLUE}${_delegations_count}${NC}"
                      println DEBUG "\nDelegator list:"
                      for pubkey_hex in ${_delegator_addresses//;/ }; do
                        echo
                        unset delegation_wallet
                        wallet_match=$(grep -r ${pubkey_hex:2} ${WALLET_FOLDER} | head -n1)
                        if [[ -n ${wallet_match} ]]; then
                          println DEBUG "Wallet:           ${FG_GREEN}$(basename ${wallet_match%/*})${NC}"
                        fi
                        println ACTION "${CCLI} ${NETWORK_ERA} stake-address build --stake-verification-key ${pubkey_hex:2} ${NETWORK_IDENTIFIER}"
                        stake_addr=$(${CCLI} ${NETWORK_ERA} stake-address build --stake-verification-key ${pubkey_hex:2} ${NETWORK_IDENTIFIER})
                        println DEBUG "Stake address:    ${FG_LGRAY}${stake_addr}${NC}"
                        delegator_status_url="${CATALYST_API}/registration/delegations/${pubkey_hex}"
                        println ACTION "curl -sSL -m ${CURL_TIMEOUT} -f -H \"Content-Type: application/json\" ${delegator_status_url}"
                        if ! delegator_status=$(curl -sSL -m ${CURL_TIMEOUT} -f -H "Content-Type: application/json" "${delegator_status_url}" 2>&1); then
                          println ERROR "${FG_RED}ERROR${NC}: failure during Catalyst delegation query!\n${delegator_status}"; continue
                        fi
                        while IFS=',' read -r _reward_address _reward_payable _raw_power; do
                          payable_color=$([[ ${_reward_payable} = false ]] && echo "${FG_YELLOW}" || echo "${FG_GREEN}")
                          println DEBUG "Reward address:   ${FG_LGRAY}${_reward_address}${NC}"
                          println DEBUG "Reward payable:   ${payable_color}${_reward_payable}${NC}"
                          println DEBUG "Raw power:        ${FG_LBLUE}$(formatLovelace ${_raw_power})${NC}"
                        done < <( jq -cr '"\(.reward_address),\(.reward_payable),\(.raw_power)"' <<< "${delegator_status}" )
                      done
                    done < <( jq -cr '"\(.last_updated),\(.final),\(.voter_info.voting_power),\(.voter_info.delegations_count),\(.voter_info.delegator_addresses | join(";"))"' <<< "${catalyst_status}" )
                    waitToProceed && continue
                    ;; ###################################################################
                esac # vote sub OPERATION
              done # vote loop
              ;; ###################################################################
          esac # vote sub OPERATION
        done # vote loop
        ;; ###################################################################
      blocks)
        clear
        println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        println " >> BLOCKS"
        println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        if ! command -v sqlite3 >/dev/null; then
          println ERROR "${FG_RED}ERROR${NC}: sqlite3 not found!"
          waitToProceed && continue
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
               waitToProceed && continue
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
                 printf '|'; printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" "" | tr " " "="; printf '|\n'
                 printf "| %-5s | %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_LBLUE}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "Epoch" "Leader" "Ideal" "Luck" "Adopted" "Confirmed" "Missed" "Ghosted" "Stolen" "Invalid"
                 printf '|'; printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" "" | tr " " "="; printf '|\n'
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
                   printf "| ${FG_LGRAY}%-5s${NC} | ${FG_LGRAY}%-6s${NC} | ${FG_LGRAY}%-${ideal_len}s${NC} | ${FG_LGRAY}%-${luck_len}s${NC} | ${FG_LBLUE}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "${current_epoch}" "${leader_cnt}" "${epoch_stats[0]}" "${epoch_stats[1]}" "${adopted_cnt}" "${confirmed_cnt}" "${missed_cnt}" "${ghosted_cnt}" "${stolen_cnt}" "${invalid_cnt}"
                   ((current_epoch--))
                 done
                 printf '|'; printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" "" | tr " " "="; printf '|\n'
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
               waitToProceed && continue
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
               printf '|'; printf "%$((6+ideal_len+luck_len+7+9+6+7+6+7+24+2))s" "" | tr " " "="; printf '|\n'
               printf "| %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_LBLUE}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "Leader" "Ideal" "Luck" "Adopted" "Confirmed" "Missed" "Ghosted" "Stolen" "Invalid"
               printf '|'; printf "%$((6+ideal_len+luck_len+7+9+6+7+6+7+24+2))s" "" | tr " " "="; printf '|\n'
               printf "| ${FG_LGRAY}%-6s${NC} | ${FG_LGRAY}%-${ideal_len}s${NC} | ${FG_LGRAY}%-${luck_len}s${NC} | ${FG_LBLUE}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "${leader_cnt}" "${epoch_stats[0]}" "${epoch_stats[1]}" "${adopted_cnt}" "${confirmed_cnt}" "${missed_cnt}" "${ghosted_cnt}" "${stolen_cnt}" "${invalid_cnt}"
               printf '|'; printf "%$((6+ideal_len+luck_len+7+9+6+7+6+7+24+2))s" "" | tr " " "="; printf '|\n'
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
                 printf '|'; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+17))s" "" | tr " " "="; printf '|\n'
                 printf "| %-${#leader_cnt}s | %-${status_len}s | %-${block_len}s | %-${slot_len}s | %-${slot_in_epoch_len}s | %-${at_len}s |\n" "#" "Status" "Block" "Slot" "SlotInEpoch" "Scheduled At"
                 printf '|'; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+17))s" "" | tr " " "="; printf '|\n'
                 while IFS='|' read -r status block slot slot_in_epoch at; do
                   at=$(TZ="${BLOCKLOG_TZ}" date '+%F %T %Z' --date="${at}")
                   [[ ${block} -eq 0 ]] && block="-"
                   printf "| ${FG_LGRAY}%-${#leader_cnt}s${NC} | ${FG_LGRAY}%-${status_len}s${NC} | ${FG_LGRAY}%-${block_len}s${NC} | ${FG_LGRAY}%-${slot_len}s${NC} | ${FG_LGRAY}%-${slot_in_epoch_len}s${NC} | ${FG_LGRAY}%-${at_len}s${NC} |\n" "${block_cnt}" "${status}" "${block}" "${slot}" "${slot_in_epoch}" "${at}"
                   ((block_cnt++))
                 done < <(sqlite3 "${BLOCKLOG_DB}" "SELECT status, block, slot, slot_in_epoch, at FROM blocklog WHERE epoch=${epoch_enter} ORDER BY slot;" 2>/dev/null)
                 printf '|'; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+17))s" "" | tr " " "="; printf '|\n'
               elif [[ ${view} -eq 2 ]]; then
                 printf '|'; printf "%$((${#leader_cnt}+status_len+slot_len+size_len+hash_len+14))s" "" | tr " " "="; printf '|\n'
                 printf "| %-${#leader_cnt}s | %-${status_len}s | %-${slot_len}s | %-${size_len}s | %-${hash_len}s |\n" "#" "Status" "Slot" "Size" "Hash"
                 printf '|'; printf "%$((${#leader_cnt}+status_len+slot_len+size_len+hash_len+14))s" "" | tr " " "="; printf '|\n'
                 while IFS='|' read -r status slot size hash; do
                   [[ ${size} -eq 0 ]] && size="-"
                   [[ -z ${hash} ]] && hash="-"
                   printf "| ${FG_LGRAY}%-${#leader_cnt}s${NC} | ${FG_LGRAY}%-${status_len}s${NC} | ${FG_LGRAY}%-${slot_len}s${NC} | ${FG_LGRAY}%-${size_len}s${NC} | ${FG_LGRAY}%-${hash_len}s${NC} |\n" "${block_cnt}" "${status}" "${slot}" "${size}" "${hash}"
                   ((block_cnt++))
                 done < <(sqlite3 "${BLOCKLOG_DB}" "SELECT status, slot, size, hash FROM blocklog WHERE epoch=${epoch_enter} ORDER BY slot;" 2>/dev/null)
                 printf '|'; printf "%$((${#leader_cnt}+status_len+slot_len+size_len+hash_len+14))s" "" | tr " " "="; printf '|\n'
               elif [[ ${view} -eq 3 ]]; then
                 printf '|'; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+size_len+hash_len+23))s" "" | tr " " "="; printf '|\n'
                 printf "| %-${#leader_cnt}s | %-${status_len}s | %-${block_len}s | %-${slot_len}s | %-${slot_in_epoch_len}s | %-${at_len}s | %-${size_len}s | %-${hash_len}s |\n" "#" "Status" "Block" "Slot" "SlotInEpoch" "Scheduled At" "Size" "Hash"
                 printf '|'; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+size_len+hash_len+23))s" "" | tr " " "="; printf '|\n'
                 while IFS='|' read -r status block slot slot_in_epoch at size hash; do
                   at=$(TZ="${BLOCKLOG_TZ}" date '+%F %T %Z' --date="${at}")
                   [[ ${block} -eq 0 ]] && block="-"
                   [[ ${size} -eq 0 ]] && size="-"
                   [[ -z ${hash} ]] && hash="-"
                   printf "| ${FG_LGRAY}%-${#leader_cnt}s${NC} | ${FG_LGRAY}%-${status_len}s${NC} | ${FG_LGRAY}%-${block_len}s${NC} | ${FG_LGRAY}%-${slot_len}s${NC} | ${FG_LGRAY}%-${slot_in_epoch_len}s${NC} | ${FG_LGRAY}%-${at_len}s${NC} | ${FG_LGRAY}%-${size_len}s${NC} | ${FG_LGRAY}%-${hash_len}s${NC} |\n" "${block_cnt}" "${status}" "${block}" "${slot}" "${slot_in_epoch}" "${at}" "${size}" "${hash}"
                   ((block_cnt++))
                 done < <(sqlite3 "${BLOCKLOG_DB}" "SELECT status, block, slot, slot_in_epoch, at, size, hash FROM blocklog WHERE epoch=${epoch_enter} ORDER BY slot;" 2>/dev/null)
                 printf '|'; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+size_len+hash_len+23))s" "" | tr " " "="; printf '|\n'
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
        waitToProceed && continue
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
              waitToProceed && continue
            fi
            if ! mkdir -p "${backup_path}"; then println ERROR "${FG_RED}ERROR${NC}: failed to create backup directory:\n${backup_path}" && waitToProceed && continue; fi
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
            [[ ${backup_cnt} -eq 0 ]] && println "\nNo folders found to include in backup :(" && waitToProceed && continue
            echo
            if [[ ${#excluded_files[@]} -gt 0 ]]; then
              println ACTION "tar ${excluded_files[*]} -cf ${backup_file} ${backup_list[*]}"
              if ! stdout=$(tar "${excluded_files[@]}" -cf "${backup_file}" "${backup_list[@]}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during tarball creation:\n${stdout}" && waitToProceed && continue; fi
              println ACTION "gzip ${backup_file}"
              if ! stdout=$(gzip "${backup_file}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: gzip error:\n${stdout}" && waitToProceed && continue; fi
              backup_file+=".gz"
            else
              println ACTION "tar -cf ${backup_file} ${backup_list[*]}"
              if ! stdout=$(tar -cf "${backup_file}" "${backup_list[@]}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during tarball creation:\n${stdout}" && waitToProceed && continue; fi
              println ACTION "gzip ${backup_file}"
              if ! stdout=$(gzip "${backup_file}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: gzip error:\n${stdout}" && waitToProceed && continue; fi
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
              waitToProceed && continue
            fi
            if ! restore_path="$(mktemp -d "${TMP_DIR}/restore_XXXXXXXXXX")"; then println ERROR "${FG_RED}ERROR${NC}: failed to create restore directory:\n${restore_path}" && waitToProceed && continue; fi
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
                waitToProceed && continue
              fi
            fi
            println ACTION "tar xfzk ${backup_file} -C ${restore_path}"
            if ! stdout=$(tar xfzk "${backup_file}" -C "${restore_path}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during tarball extraction:\n${stdout}" && waitToProceed && continue; fi
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
            [[ ${restore_cnt} -eq 0 ]] && println "\nNothing in backup file to restore :(" && waitToProceed && continue
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
              if ! mkdir -p "${archive_dest}"; then println ERROR "${FG_RED}ERROR${NC}: failed to create archive directory:\n${archive_dest}" && waitToProceed && continue; fi
              archive_file="${archive_dest}/archive_$(date '+%Y%m%d%H%M%S').tar.gz"
              println ACTION "tar cfz ${archive_file} ${archive_list[*]}"
              if ! stdout=$(tar cfz "${archive_file}" "${archive_list[@]}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during archive/backup:\n${stdout}" && waitToProceed && continue; fi
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
              if ! stdout=$(cp -rf "${item}" "$(dirname "${dest_path}")" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during retore copy:\n${stdout}" && waitToProceed && continue; fi
            done
            println "Backup ${FG_LGRAY}$(basename "${backup_file}")${NC} successfully restored!"
            ;;
          2) continue ;;
        esac
        waitToProceed && continue
        ;; ###################################################################
      advanced)
        while true; do # Advanced loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> ADVANCED"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Developer & Advanced features\n"\
						" ) Metadata       - create and optionally post metadata on-chain"\
						" ) Asset          - asset nanagement"\
						" ) MultiSig       - create a multi-signature wallet"\
						" ) Delete Keys    - delete all sign/cold keys from CNTools (wallet|pool|asset)"\
						"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Operation\n"
          select_opt "[m] Metadata" "[a] Asset" "[s] MultiSig" "[x] Delete Private Keys" "[h] Home"
          case $? in
            0) SUBCOMMAND="metadata" ;;
            1) SUBCOMMAND="asset" ;;
            2) SUBCOMMAND="multisig" ;;
            3) SUBCOMMAND="del-keys" ;;
            4) break ;;
          esac
          case $SUBCOMMAND in  
            metadata)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> ADVANCED >> METADATA"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available to pay for transaction fee!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
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
                      waitToProceed && continue
                    fi
                    println DEBUG "$(cat "${metafile}")\n"
                    ;;
                  1) tput sc && echo
                    getAnswerAnyCust meta_json_url "Enter URL to JSON metadata file"
                    if [[ ! "${meta_json_url}" =~ https?://.* ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: invalid URL format"
                      waitToProceed && continue
                    fi
                    if ! curl -sL -m ${CURL_TIMEOUT} -o "${metafile}" ${meta_json_url} || ! jq -er . "${metafile}" &>/dev/null; then
                      println ERROR "${FG_RED}ERROR${NC}: metadata download failed, please make sure the URL point to a valid JSON file!"
                      waitToProceed && continue
                    fi
                    tput rc && tput ed
                    println "Metadata file successfully downloaded to: ${FG_LGRAY}${metafile}${NC}"
                    ;;
                  2) println "Add an example metadata JSON scaffold?"
                    select_opt "[y] Yes" "[n] No"
                    case $? in
                      0) jq . <<< '{"1815":{"name":"ADA Lovelace","age":36,"parents":[{"id":0,"name":"George Gordon Byron"},{"id":1,"name":"Anne Isabella Byron"}]}}' > "${metafile}" ;;
                      1) : ;; # do nothing
                    esac
                    tput sc
                    DEFAULTEDITOR="$(command -v nano &>/dev/null && echo 'nano' || echo 'vi')"
                    println OFF "\nPaste or enter the metadata text, opening text editor ${FG_LGRAY}${DEFAULTEDITOR}${NC}"
                    println OFF "${FG_YELLOW}Please don't change default file path when saving${NC}"
                    waitToProceed "press any key to open ${DEFAULTEDITOR}"
                    ${DEFAULTEDITOR} "${metafile}"
                    if [[ ! -f "${metafile}" ]] || ! jq -er . "${metafile}" &>/dev/null; then
                      println ERROR "${FG_RED}ERROR${NC}: file not found or invalid JSON format"
                      println ERROR "File: ${FG_LGRAY}${metafile}${NC}"
                      waitToProceed && continue
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
              println DEBUG "\nSelect wallet to pay for metadata transaction fee"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for metadata transaction fee!" && waitToProceed && continue ;;
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for metadata transaction fee!" && waitToProceed && continue ;;
                esac
              fi
              echo
              getWalletBalance ${wallet_name} true true true true
              if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                # Both payment and base address available with funds, let user choose what to use
                println DEBUG "Select source wallet address"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
                echo
                select_opt "[b] Base (default)" "[e] Payment" "[Esc] Cancel"
                case $? in
                  0) addr="${base_addr}"; lovelace=${base_lovelace} ;;
                  1) addr="${pay_addr}";  lovelace=${pay_lovelace} ;;
                  2) continue ;;
                esac
              elif [[ ${pay_lovelace} -gt 0 ]]; then
                addr="${pay_addr}"
                lovelace=${pay_lovelace}
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
              elif [[ ${base_lovelace} -gt 0 ]]; then
                addr="${base_addr}"
                lovelace=${base_lovelace}
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                waitToProceed && continue
              fi
              if ! sendMetadata; then
                waitToProceed && continue
              fi
              echo
              if ! verifyTx ${addr}; then waitToProceed && continue; fi
              echo
              println "Metadata successfully posted on-chain"
              waitToProceed && continue
              ;; ###################################################################
            asset)
              while true; do # Asset loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> ADVANCED >> ASSET"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Asset Token Management\n"\
									" ) Create Policy  - create a new asset policy"\
									" ) List Assets    - list created/minted policies/assets (local)"\
									" ) Show Asset     - show minted asset information"\
									" ) Decrypt Policy - remove write protection and decrypt policy"\
									" ) Encrypt Policy - encrypt policy sign key and make all files immutable"\
									" ) Mint Asset     - mint new assets for selected policy"\
									" ) Burn Asset     - burn a given amount of assets in selected wallet"\
									" ) Register Asset - create/update JSON submission file for Cardano Token Registry"\
									"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select Asset Operation\n"
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
                    println " >> ADVANCED >> ASSET >> CREATE POLICY"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    getAnswerAnyCust policy_name "Internal name to give the generated policy"
                    # Remove unwanted characters from policy name
                    policy_name=${policy_name//[^[:alnum:]]/_}
                    if [[ -z "${policy_name}" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: Empty policy name, please retry!"
                      waitToProceed && continue
                    fi
                    policy_folder="${ASSET_FOLDER}/${policy_name}"
                    echo
                    if ! mkdir -p "${policy_folder}"; then
                      println ERROR "${FG_RED}ERROR${NC}: Failed to create directory for policy:\n${policy_folder}"
                      waitToProceed && continue
                    fi
                    # Policy filenames
                    policy_sk_file="${policy_folder}/${ASSET_POLICY_SK_FILENAME}"
                    policy_vk_file="${policy_folder}/${ASSET_POLICY_VK_FILENAME}"
                    policy_script_file="${policy_folder}/${ASSET_POLICY_SCRIPT_FILENAME}"
                    policy_id_file="${policy_folder}/${ASSET_POLICY_ID_FILENAME}"
                    if [[ $(find "${policy_folder}" -type f -print0 | wc -c) -gt 0 ]]; then
                      println "${FG_RED}WARN${NC}: A policy ${FG_GREEN}${policy_name}${NC} already exist!"
                      println "      Choose another name or delete the existing one"
                      waitToProceed && continue
                    fi
                    println ACTION "${CCLI} ${NETWORK_ERA} address key-gen --verification-key-file ${policy_vk_file} --signing-key-file ${policy_sk_file}"
                    if ! stdout=$(${CCLI} ${NETWORK_ERA} address key-gen --verification-key-file "${policy_vk_file}" --signing-key-file "${policy_sk_file}" 2>&1); then
                      println ERROR "${FG_RED}ERROR${NC}: failure during policy key creation!\n${stdout}"; safeDel "${policy_folder}"; waitToProceed && continue
                    fi
                    println ACTION "${CCLI} ${NETWORK_ERA} address key-hash --payment-verification-key-file ${policy_vk_file}"
                    if ! policy_key_hash=$(${CCLI} ${NETWORK_ERA} address key-hash --payment-verification-key-file "${policy_vk_file}" 2>&1); then
                      println ERROR "${FG_RED}ERROR${NC}: failure during policy verification key hashing!\n${policy_key_hash}"; safeDel "${policy_folder}"; waitToProceed && continue
                    fi
                    println DEBUG "How long do you want the policy to be valid? (0/blank=unlimited)"
                    println DEBUG "${FG_YELLOW}Setting a limit will prevent you from minting/burning assets after the policy expire !!\nLeave blank/unlimited if unsure and just press enter${NC}"
                    getAnswerAnyCust ttl_enter "TTL (in seconds)"
                    ttl_enter=${ttl_enter:-0}
                    if ! isNumber ${ttl_enter}; then
                      println ERROR "\n${FG_RED}ERROR${NC}: invalid TTL number, non digit characters found: ${ttl_enter}"
                      safeDel "${policy_folder}"; waitToProceed && continue
                    fi
                    if [[ ${ttl_enter} -eq 0 ]]; then
                      echo "{ \"keyHash\": \"${policy_key_hash}\", \"type\": \"sig\" }" > "${policy_script_file}"
                    else
                      ttl=$(( $(getSlotTipRef) + (ttl_enter/SLOT_LENGTH) ))
                      echo "{ \"type\": \"all\", \"scripts\": [ { \"slot\": ${ttl}, \"type\": \"before\" }, { \"keyHash\": \"${policy_key_hash}\", \"type\": \"sig\" } ] }" > "${policy_script_file}"
                    fi
                    println ACTION "${CCLI} ${NETWORK_ERA} transaction policyid --script-file ${policy_script_file}"
                    if ! policy_id=$(${CCLI} ${NETWORK_ERA} transaction policyid --script-file "${policy_script_file}" 2>&1); then
                      println ERROR "${FG_RED}ERROR${NC}: failure during policy ID generation!\n${policy_id}"; safeDel "${policy_folder}"; waitToProceed && continue
                    fi
                    echo "${policy_id}" > "${policy_id_file}"
                    chmod 600 "${policy_folder}/"*
                    echo
                    println "Policy Name   : ${FG_GREEN}${policy_name}${NC}"
                    println "Policy ID     : ${FG_LGRAY}${policy_id}${NC}"
                    println "Policy Expire : $([[ ${ttl_enter} -eq 0 ]] && echo "${FG_LGRAY}unlimited${NC}" || echo "${FG_LGRAY}$(getDateFromSlot ${ttl} '%(%F %T %Z)T')${NC}, ${FG_LGRAY}$(timeLeft $((ttl-$(getSlotTipRef))))${NC} remaining")"
                    println DEBUG "\nYou can now start minting your custom assets using this Policy!"
                    waitToProceed && continue
                    ;; ###################################################################
                  list-assets)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> ASSET >> LIST ASSETS"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No policies or assets found!${NC}" && waitToProceed && continue
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
                    waitToProceed && continue
                    ;; ###################################################################
                  show-asset)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> ASSET >> SHOW ASSET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No policies or assets found!${NC}" && waitToProceed && continue
                    println DEBUG "Select minted asset to show information for"
                    selectAsset
                    case $? in
                      1) waitToProceed; continue ;;
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
                    waitToProceed && continue
                    ;; ###################################################################
                  decrypt-policy)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> ASSET >> DECRYPT / UNLOCK POLICY"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No policies available!${NC}" && waitToProceed && continue
                    println DEBUG "Select policy to decrypt"
                    selectPolicy "encrypted"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    filesUnlocked=0
                    keysDecrypted=0
                    echo
                    println DEBUG "Removing write protection from all policy files"
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
                      println "Decrypting GPG encrypted policy key"
                      if ! getPasswordCust; then # $password variable populated by getPasswordCust function
                        println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                        waitToProceed && continue
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
                      println DEBUG "Use 'ADVANCED >> ASSET >> ENCRYPT / LOCK POLICY' to re-lock"
                    fi
                    waitToProceed && continue
                    ;; ###################################################################
                  encrypt-policy)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> ASSET >> ENCRYPT / LOCK POLICY"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No policies available!${NC}" && waitToProceed && continue
                    println DEBUG "Select policy to encrypt"
                    selectPolicy "encrypted"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    filesLocked=0
                    keysEncrypted=0
                    if [[ $(find "${ASSET_FOLDER}/${policy_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -le 0 ]]; then
                      echo
                      println DEBUG "Encrypting policy signing key with GPG"
                      if ! getPasswordCust confirm; then # $password variable populated by getPasswordCust function
                        println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                        waitToProceed && continue
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
                      waitToProceed && continue
                    fi
                    echo
                    println DEBUG "Write protecting all policy files with 400 permission and if enabled 'chattr +i'"
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
                      println DEBUG "Use 'ADVANCED >> ASSET >> DECRYPT / UNLOCK POLICY' to unlock"
                    fi
                    waitToProceed && continue
                    ;; ###################################################################
                  mint-asset)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> ASSET >> MINT ASSET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    echo
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No policies found!${NC}\n\nPlease first create a policy to mint asset with" && waitToProceed && continue
                    println DEBUG "Select the policy to use when minting the asset"
                    selectPolicy "all" "${ASSET_POLICY_SK_FILENAME}" "${ASSET_POLICY_VK_FILENAME}" "${ASSET_POLICY_SCRIPT_FILENAME}" "${ASSET_POLICY_ID_FILENAME}"
                    case $? in
                      1) waitToProceed; continue ;;
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
                    [[ ${policy_ttl} -gt 0 && ${policy_ttl} -lt $(getSlotTipRef) ]] && println ERROR "${FG_RED}ERROR${NC}: Policy expired!" && waitToProceed && continue
                    echo
                    if [[ $(find "${policy_folder}" -type f -name '*.asset' -print0 | wc -c) -gt 0 ]]; then
                      println DEBUG "Assets minted for this Policy\n"
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
                    [[ ${asset_name} =~ ^[^[:alnum:]]$ ]] && println ERROR "${FG_RED}ERROR${NC}: Asset name should only contain alphanummeric chars!" && waitToProceed && continue
                    [[ ${#asset_name} -gt 32 ]] && println ERROR "${FG_RED}ERROR${NC}: Asset name is limited to 32 chars in length!" && waitToProceed && continue
                    asset_file="${policy_folder}/${asset_name// /_}.asset"
                    echo
                    getAnswerAnyCust assets_to_mint "Amount (commas allowed as thousand separator)"
                    assets_to_mint="${assets_to_mint//,}"
                    [[ -z "${assets_to_mint}" ]] && println ERROR "${FG_RED}ERROR${NC}: Amount empty, please set a valid integer number!" && waitToProceed && continue
                    if ! isNumber ${assets_to_mint}; then println ERROR "${FG_RED}ERROR${NC}: Invalid number, should be an integer number. Decimals not allowed!" && waitToProceed && continue; fi
                    [[ -f "${asset_file}" ]] && asset_minted=$(( $(jq -r .minted "${asset_file}") + assets_to_mint )) || asset_minted=${assets_to_mint}
                    metafile_param=""
                    println DEBUG "\nDo you want to attach a metadata JSON file to the minting transaction?"
                    select_opt "[n] No" "[y] Yes"
                    case $? in
                      0) : ;; # do nothing
                      1) fileDialog "Enter path to metadata JSON file" "${TMP_DIR}/" && echo
                        metafile=${file}
                        [[ -z "${metafile}" ]] && println ERROR "${FG_RED}ERROR${NC}: Metadata file path empty!" && waitToProceed && continue
                        [[ ! -f "${metafile}" ]] && println ERROR "${FG_RED}ERROR${NC}: File not found: ${metafile}" && waitToProceed && continue
                        if ! jq -er . "${metafile}"; then println ERROR "${FG_RED}ERROR${NC}: Metadata file not a valid json file!" && waitToProceed && continue; fi
                        metafile_param="--metadata-json-file ${metafile}"
                        ;;
                    esac
                    println DEBUG "\nSelect wallet to mint assets on (also used for transaction fee)"
                    if [[ ${op_mode} = "online" ]]; then
                      selectWallet "balance"
                      case $? in
                        1) waitToProceed; continue ;;
                        2) continue ;;
                      esac
                      getWalletType ${wallet_name}
                      case $? in
                        2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                        3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                      esac
                    else
                      selectWallet "balance"
                      case $? in
                        1) waitToProceed; continue ;;
                        2) continue ;;
                      esac
                    fi
                    echo
                    getWalletBalance ${wallet_name} true true true true
                    if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                      # Both payment and base address available with funds, let user choose what to use
                      println DEBUG "Select source wallet address"
                      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                        println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                        println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                      fi
                      echo
                      select_opt "[b] Base (default)" "[e] Payment" "[Esc] Cancel"
                      case $? in
                        0) addr="${base_addr}"; lovelace=${base_lovelace} ;;
                        1) addr="${pay_addr}" ; lovelace=${pay_lovelace} ;;
                        2) continue ;;
                      esac
                      echo
                    elif [[ ${pay_lovelace} -gt 0 ]]; then
                      addr="${pay_addr}"
                      lovelace=${pay_lovelace}
                      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                        println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA\n" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                      fi
                    elif [[ ${base_lovelace} -gt 0 ]]; then
                      addr="${base_addr}"
                      lovelace=${base_lovelace}
                      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                        println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA\n" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                      fi
                    else
                      println ERROR "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                      waitToProceed && continue
                    fi
                    if ! mintAsset; then
                      waitToProceed && continue
                    fi
                    if [[ ! -f "${asset_file}" ]]; then echo "{}" > "${asset_file}"; fi
                    assetJSON=$( jq ". += {minted: \"${asset_minted}\", name: \"${asset_name}\", policyID: \"${policy_id}\", assetName: \"$(asciiToHex "${asset_name}")\", policyValidBeforeSlot: \"${policy_ttl}\", lastUpdate: \"$(date -R)\", lastAction: \"Minted $(formatAsset ${assets_to_mint})\"}" < "${asset_file}")
                    echo -e "${assetJSON}" > "${asset_file}"
                    echo
                    if ! verifyTx ${addr}; then waitToProceed && continue; fi
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
                    waitToProceed && continue
                    ;; ###################################################################
                  burn-asset)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> ASSET >> BURN ASSET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    echo
                    println DEBUG "Select wallet with assets to burn"
                    if [[ ${op_mode} = "online" ]]; then
                      selectWallet "balance"
                      case $? in
                        1) waitToProceed; continue ;;
                        2) continue ;;
                      esac
                      getWalletType ${wallet_name}
                      case $? in
                        0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet for asset burning!" && waitToProceed && continue ;;
                        2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                        3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                      esac
                    else
                      selectWallet "balance"
                      case $? in
                        1) waitToProceed; continue ;;
                        2) continue ;;
                      esac
                      getWalletType ${wallet_name}
                      case $? in
                        0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet for asset burning!" && waitToProceed && continue ;;
                      esac
                    fi
                    # Let user choose asset on wallet to burn, both base and payment, fee payed with same address
                    assets_on_wallet=()
                    getWalletBalance ${wallet_name} true true true true
                    for asset in "${!base_assets[@]}"; do
                      [[ ${asset} = "lovelace" ]] && continue
                      IFS='.' read -ra asset_arr <<< "${asset}"
                      [[ -z ${asset_arr[1]} ]] && asset_ascii_name="" || asset_ascii_name=$(hexToAscii ${asset_arr[1]})
                      assets_on_wallet+=( "${asset} (${asset_ascii_name}) [base addr]" )
                    done
                    for asset in "${!pay_assets[@]}"; do
                      [[ ${asset} = "lovelace" ]] && continue
                      IFS='.' read -ra asset_arr <<< "${asset}"
                      [[ -z ${asset_arr[1]} ]] && asset_ascii_name="" || asset_ascii_name=$(hexToAscii ${asset_arr[1]})
                      assets_on_wallet+=( "${asset} (${asset_ascii_name}) [payment addr]" )
                    done
                    echo
                    [[ ${#assets_on_wallet[@]} -eq 0 ]] && println ERROR "${FG_RED}ERROR${NC}: Wallet doesn't contain any assets!" && waitToProceed && continue
                    println DEBUG "Select Asset to burn"
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
                      lovelace=${base_assets[lovelace]}
                    else
                      addr=${pay_addr}
                      wallet_source="payment"
                      curr_asset_amount=${pay_assets[${asset}]}
                      lovelace=${pay_assets[lovelace]}
                    fi
                    echo
                    
                    # Search policies for a match
                    asset_file=""
                    while IFS= read -r -d '' file; do
                      [[ ${asset_arr[0]} = "$(jq -r .policyID ${file})" ]] && asset_file="${file}" && break
                    done < <(find "${ASSET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name '*.asset' -print0)
                    [[ -z "${asset_file}" ]] && println ERROR "${FG_RED}ERROR${NC}: Searched all available policies in '${ASSET_FOLDER}' for matching '.asset' file but non found!" && waitToProceed && continue
                    
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
                    [[ ${policy_ttl} -gt 0 && ${policy_ttl} -lt $(getSlotTipRef) ]] && println ERROR "${FG_RED}ERROR${NC}: Policy expired!" && waitToProceed && continue
                    # ask amount to burn
                    println DEBUG "Available assets to burn: ${FG_LBLUE}$(formatAsset "${curr_asset_amount}")${NC}\n"
                    getAnswerAnyCust assets_to_burn "Amount (commas allowed as thousand separator)"
                    assets_to_burn="${assets_to_burn//,}"
                    [[ ${assets_to_burn} = "all" ]] && assets_to_burn=${curr_asset_amount}
                    if ! isNumber ${assets_to_burn}; then println ERROR "${FG_RED}ERROR${NC}: Invalid number, should be an integer number. Decimals not allowed!" && waitToProceed && continue; fi
                    [[ ${assets_to_burn} -gt ${curr_asset_amount} ]] && println ERROR "${FG_RED}ERROR${NC}: Amount exceeding assets in address, you can only burn ${FG_LBLUE}$(formatAsset "${asset_amount}")${NC}" && waitToProceed && continue
                    asset_minted=$(( $(jq -r .minted "${asset_file}") - assets_to_burn ))
                    # Attach metadata?
                    metafile_param=""
                    println DEBUG "\nDo you want to attach a metadata JSON file to the burning transaction?"
                    select_opt "[n] No" "[y] Yes"
                    case $? in
                      0) : ;; # do nothing
                      1) fileDialog "Enter path to metadata JSON file" "${TMP_DIR}/" && echo
                        metafile=${file}
                        [[ -z "${metafile}" ]] && println ERROR "${FG_RED}ERROR${NC}: Metadata file path empty!" && waitToProceed && continue
                        [[ ! -f "${metafile}" ]] && println ERROR "${FG_RED}ERROR${NC}: File not found: ${metafile}" && waitToProceed && continue
                        if ! jq -er . "${metafile}"; then println ERROR "${FG_RED}ERROR${NC}: Metadata file not a valid json file!" && waitToProceed && continue; fi
                        metafile_param="--metadata-json-file ${metafile}"
                        ;;
                    esac
                    echo
                    # Call burn helper function
                    if ! burnAsset; then
                      waitToProceed && continue
                    fi
                    # Update asset file
                    if [[ ! -f "${asset_file}" ]]; then echo "{}" > "${asset_file}"; fi
                    assetJSON=$( jq ". += {minted: \"${asset_minted}\", name: \"$(hexToAscii "${asset_name}")\", policyID: \"${policy_id}\", policyValidBeforeSlot: \"${policy_ttl}\", lastUpdate: \"$(date -R)\", lastAction: \"Burned $(formatAsset ${assets_to_burn})\"}" < "${asset_file}")
                    echo -e "${assetJSON}" > "${asset_file}"
                    echo
                    if ! verifyTx ${addr}; then waitToProceed && continue; fi
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
                    waitToProceed && continue
                    ;; ###################################################################
                  register-asset)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> ASSET >> REGISTER ASSET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    if ! cmdAvailable "token-metadata-creator"; then
                      println ERROR "Please follow instructions on Guild Operators site to download or build the tool:"
                      println ERROR "${FG_YELLOW}https://cardano-community.github.io/guild-operators/Build/offchain-metadata-tools/${NC}"
                      waitToProceed && continue
                    fi
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No policies found!${NC}\n\nPlease first create a policy to use for Cardano Token Registry" && waitToProceed && continue
                    println DEBUG "Select the policy to use for Cardano Token Registry"
                    selectPolicy "all" "${ASSET_POLICY_SK_FILENAME}" "${ASSET_POLICY_SCRIPT_FILENAME}" "${ASSET_POLICY_ID_FILENAME}"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    policy_folder="${ASSET_FOLDER}/${policy_name}"
                    # Policy filenames
                    policy_sk_file="${policy_folder}/${ASSET_POLICY_SK_FILENAME}"
                    policy_script_file="${policy_folder}/${ASSET_POLICY_SCRIPT_FILENAME}"
                    policy_id="$(cat "${policy_folder}/${ASSET_POLICY_ID_FILENAME}")"
                    echo
                    if [[ $(find "${policy_folder}" -type f -name '*.asset' -print0 | wc -c) -gt 0 ]]; then
                      println DEBUG "Assets previously minted for this Policy\n"
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
                    [[ ${asset_name} =~ ^[^[:alnum:]]$ ]] && println ERROR "${FG_RED}ERROR${NC}: Asset name should only contain alphanummeric chars!" && waitToProceed && continue
                    [[ ${#asset_name} -gt 32 ]] && println ERROR "${FG_RED}ERROR${NC}: Asset name is limited to 32 chars in length!" && waitToProceed && continue
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
                    println DEBUG "Enter metadata (optional fields can be left empty)"
                    getAnswerAnyCust meta_name "Name        [${FG_RED}required${NC}] (Max. 50 chars) "
                    [[ -z ${meta_name} || ${#meta_name} -gt 50 ]] && println ERROR "\n${FG_RED}ERROR${NC}: Metadata name is a required field and limited to 50 chars in length!" && waitToProceed && continue
                    getAnswerAnyCust meta_desc "Description [${FG_RED}required${NC}] (Max. 500 chars)"
                    [[ -z ${meta_desc} || ${#meta_desc} -gt 500 ]] && println ERROR "\n${FG_RED}ERROR${NC}: Metadata description is a required field and limited to 500 chars in length!" && waitToProceed && continue
                    getAnswerAnyCust meta_ticker "Ticker      [${FG_YELLOW}optional${NC}] (3-9 chars)     "
                    [[ -n ${meta_ticker} && ( ${#meta_ticker} -lt 3 || ${#meta_ticker} -gt 9 ) ]] && println ERROR "\n${FG_RED}ERROR${NC}: Metadata ticker is limited to 3-9 chars in length!" && waitToProceed && continue
                    getAnswerAnyCust meta_url "URL         [${FG_YELLOW}optional${NC}] (Max. 250 chars)"
                    [[ -n ${meta_url} && ( ! ${meta_url} =~ https://.* || ${#meta_url} -gt 250 ) ]] && println ERROR "\n${FG_RED}ERROR${NC}: Invalid metadata URL format or greater than 250 char limit!" && waitToProceed && continue
                    getAnswerAnyCust meta_decimals "Decimals    [${FG_YELLOW}optional${NC}]"
                    [[ -n ${meta_decimals} ]] && ! isNumber ${meta_decimals} && println ERROR "\n${FG_RED}ERROR${NC}: Invalid decimal number" && waitToProceed && continue
                    fileDialog "Logo/Icon   [${FG_YELLOW}optional${NC}] (PNG, <64kb)    " "${TMP_DIR}/"
                    meta_logo="${file}"
                    if [[ -n ${meta_logo} ]]; then
                      [[ ! -f ${meta_logo} ]] && println ERROR "\n${FG_RED}ERROR${NC}: Logo not found!" && waitToProceed && continue
                      [[ $(wc -c ${meta_logo} | cut -d' ' -f1) -gt 64000 ]] && println ERROR "\n${FG_RED}ERROR${NC}: Logo more than 64kb in size!" && waitToProceed && continue
                      [[ $(file -b ${meta_logo}) != "PNG"* ]] && println ERROR "\n${FG_RED}ERROR${NC}: Logo not of PNG image type!" && waitToProceed && continue
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
                    
                    pushd ${policy_folder} &>/dev/null || { println ERROR "\n${FG_RED}ERROR${NC}: unable to change directory to: ${policy_folder}" && waitToProceed && continue; }
                    
                    # Create JSON draft
                    println DEBUG false "\nCreating Cardano Metadata Registry JSON draft file ..."
                    ! meta_file=$(token-metadata-creator "${cmd_args[@]}" 2>&1) && println ERROR "\n${FG_RED}ERROR${NC}: failure during token-metadata-creator draft:\n${meta_file}" && popd >/dev/null && waitToProceed && continue
                    println DEBUG " ${FG_GREEN}OK${NC}!"
                    
                    # Update the sequence number if needed
                    if [[ ${sequence_number} -ne 0 ]]; then
                      println DEBUG false "Updating sequence number to ${FG_LBLUE}${sequence_number}${NC} ..."
                      ! sed -i "s/\"sequenceNumber\":\ .*,/\"sequenceNumber\":\ ${sequence_number},/g" ${meta_file} && popd >/dev/null && waitToProceed && continue
                      println DEBUG " ${FG_GREEN}OK${NC}!"
                    fi
                    
                    # Signing draft file with policy signing key
                    println DEBUG false "Signing draft file with policy signing key ..."
                    ! meta_file=$(token-metadata-creator entry ${asset_subject} -a "${policy_sk_file}" 2>&1) && println ERROR "\n${FG_RED}ERROR${NC}: failure during token-metadata-creator signing:\n${meta_file}" && popd >/dev/null && waitToProceed && continue
                    println DEBUG " ${FG_GREEN}OK${NC}!"
                    
                    # Finalizing the draft file
                    println DEBUG false "Finalizing the draft file ..."
                    ! meta_file=$(token-metadata-creator entry ${asset_subject} --finalize 2>&1) && println ERROR "\n${FG_RED}ERROR${NC}: failure during token-metadata-creator finalize:\n${meta_file}" && popd >/dev/null && waitToProceed && continue
                    println DEBUG " ${FG_GREEN}OK${NC}!"
                    
                    # Validating the final metadata registry submission file
                    println DEBUG false "Validating the final metadata registry submission file ..."
                    ! output=$(token-metadata-creator validate ${meta_file} 2>&1) && println ERROR "\n${FG_RED}ERROR${NC}: failure during token-metadata-creator validation:\n${output}" && popd >/dev/null && waitToProceed && continue
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
                    
                    waitToProceed && continue
                    
                    ;; ###################################################################
                esac # advanced >> asset sub OPERATION
              done # Asset loop
              ;; ###################################################################
            multisig)
              while true; do # MultiSig loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> ADVANCED >> MULTISIG"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Multi Signature Wallet Management\n"\
                  " ) Create Wallet  - create a new multi-signature wallet"\
                  " ) Derive Keys    - derive MultiSig keys using the 1854H paths according to CIP-1854"\
                  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select MultiSig Operation\n"
                select_opt "[c] Create" "[d] Derive Keys" "[b] Back" "[h] Home"
                case $? in
                  0) SUBCOMMAND="create-ms-wallet" ;;
                  1) SUBCOMMAND="derive-ms-keys" ;;
                  2) break ;;
                  3) break 2 ;;
                esac
                case $SUBCOMMAND in
                  create-ms-wallet)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> MULTISIG >> CREATE WALLET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    createNewWallet || continue
                    ms_wallet_name="${wallet_name}"
                    # Wallet key filenames
                    ms_pay_script_file="${WALLET_FOLDER}/${ms_wallet_name}/${WALLET_PAY_SCRIPT_FILENAME}"
                    ms_stake_script_file="${WALLET_FOLDER}/${ms_wallet_name}/${WALLET_STAKE_SCRIPT_FILENAME}"
                    if [[ $(find "${WALLET_FOLDER}/${ms_wallet_name}" -type f -print0 | wc -c) -gt 0 ]]; then
                      println "${FG_RED}WARN${NC}: A wallet ${FG_GREEN}${ms_wallet_name}${NC} already exists"
                      println "      Choose another name or delete the existing one"
                      waitToProceed && continue
                    fi
                    # pay key hashes as keys to associative array to act as a set, with stake key hash as value
                    declare -gA key_hashes=()
                    unset timelock_after
                    println OFF "Select wallet(s) / credentials (key hashes) to include in MultiSig wallet"
                    println OFF "${FG_YELLOW}!${NC} Please use 1854H (MultiSig) derived keys according to CIP-1854!"
                    println OFF "${FG_YELLOW}!${NC} Only wallets with these keys will be listed, use 'Derive Keys' option to generate them."
                    echo
                    selected_wallets=()
                    while true; do
                      println DEBUG "Select wallet or manually enter credentials?"
                      select_opt "[w] Wallet" "[c] Credentials" "[d] I'm done" "[Esc] Cancel"
                      case $? in
                        0) selectWallet "balance" "${selected_wallets[@]}" "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}" "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
                          case $? in
                            1) waitToProceed; continue ;;
                            2) continue ;;
                          esac
                          getCredentials ${wallet_name}
                          [[ -z ${ms_pay_cred} ]] && println ERROR "\n${FG_RED}ERROR${NC}: wallet MultiSig payment credentials not set!" && waitToProceed && continue
                          [[ -z ${ms_stake_cred} ]] && println ERROR "\n${FG_RED}ERROR${NC}: wallet MultiSig stake credentials not set!" && waitToProceed && continue
                          key_hashes[${ms_pay_cred}]="${ms_stake_cred}"
                          selected_wallets+=("${wallet_name}")
                          ;;
                        1) getAnswerAnyCust ms_pay_cred "MultiSig Payment Credential (key hash)"
                          [[ ${#ms_pay_cred} -ne 56 ]] && println ERROR "\n${FG_RED}ERROR${NC}: invalid payment credential entered!" && waitToProceed && continue
                          getAnswerAnyCust ms_stake_cred "MultiSig Stake Credential (key hash)"
                          [[ ${#ms_stake_cred} -ne 56 ]] && println ERROR "\n${FG_RED}ERROR${NC}: invalid stake credential entered!" && waitToProceed && continue
                          key_hashes[${ms_pay_cred}]="${ms_stake_cred}"
                          ;;
                        2) break ;;
                        3) safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; continue 2 ;;
                      esac
                      println DEBUG "\nMultiSig size: ${#key_hashes[@]} - Add more wallets / credentials to MultiSig?"
                      select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                      case $? in
                        0) break ;;
                        1) : ;;
                        2) safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; continue 2 ;;
                      esac
                    done
                    if [[ ${#key_hashes[@]} -eq 0 ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: no signers added, please add at least one"; safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; waitToProceed; continue
                    fi
                    println DEBUG "\n${#key_hashes[@]} wallets / credentials added to MultiSig, how many are required to witness the transaction?"
                    getAnswerAnyCust required_sig_cnt "Number of Required signatures"
                    if ! isNumber ${required_sig_cnt} || [[ ${required_sig_cnt} -lt 1 || ${required_sig_cnt} -gt ${#key_hashes[@]} ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: invalid signature count entered, must be above 1 and max ${#key_hashes[@]}"; safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; waitToProceed; continue
                    fi
                    println DEBUG "\nAdd time lock to MultiSig wallet by only allowing spending from wallet after a certain epoch start?"
                    select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                    case $? in
                      0) : ;;
                      1) getAnswerAnyCust epoch_no "Epoch"
                        if ! isNumber ${epoch_no}; then println ERROR "${FG_RED}ERROR${NC}: invalid epoch number entered!"; safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; waitToProceed; continue; fi
                        timelock_after=$(getEpochStart ${epoch_no})
                        ;;
                      2) safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; continue ;;
                    esac
                    # build MultiSig script
                    pay_script=$(jq -n --argjson req_sig "${required_sig_cnt}" '{type:"atLeast",required:$req_sig,scripts:[]}')
                    stake_script="${pay_script}"
                    for sig in "${!key_hashes[@]}"; do
                      pay_script=$(jq --arg sig "${sig}" '.scripts += [{type:"sig",keyHash:$sig}]' <<< "${pay_script}")
                      stake_script=$(jq --arg sig "${key_hashes[${sig}]}" '.scripts += [{type:"sig",keyHash:$sig}]' <<< "${stake_script}")
                    done
                    if [[ -n ${timelock_after} ]]; then
                      pay_script=$(jq -n --argjson after "${timelock_after}" --argjson sig_script "${jsonscript}" '{type:"all",scripts:[{type:"after",slot:$after},$sig_script]}')
                    fi
                    if ! stdout=$(jq -e . <<< "${pay_script}" > "${ms_pay_script_file}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during payment script file creation!\n${stdout}"; safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; waitToProceed && continue
                    fi
                    if ! stdout=$(jq -e . <<< "${stake_script}" > "${ms_stake_script_file}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during stake script file creation!\n${stdout}"; safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; waitToProceed && continue
                    fi

                    chmod 600 "${WALLET_FOLDER}/${ms_wallet_name}/"*
                    getBaseAddress ${ms_wallet_name}
                    getPayAddress ${ms_wallet_name}
                    getRewardAddress ${ms_wallet_name}
                    getCredentials ${ms_wallet_name}
                    echo
                    println "New MultiSig Wallet : ${FG_GREEN}${ms_wallet_name}${NC}"
                    println "Address             : ${FG_LGRAY}${base_addr}${NC}"
                    println "Payment Address     : ${FG_LGRAY}${pay_addr}${NC}"
                    println "Reward Address      : ${FG_LGRAY}${reward_addr}${NC}"
                    println "Payment Credential  : ${FG_LGRAY}${script_pay_cred}${NC}"
                    println "Reward Credential   : ${FG_LGRAY}${script_stake_cred}${NC}"
                    println DEBUG "\nYou can now send and receive ADA using the above 'Address' or 'Payment Address'."
                    println DEBUG "Note that Payment Address will not take part in staking."
                    waitToProceed && continue
                    ;; ###################################################################
                  derive-ms-keys)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> MULTISIG >> DERIVE KEYS"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    println DEBUG "Select wallet to derive MultiSig keys for (only wallets with missing keys shown)"
                    selectWallet "non-ms"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    getWalletType ${wallet_name}
                    case $? in
                      0) # Hardware wallet
                        if ! cmdAvailable "cardano-hw-cli" &>/dev/null; then
                          println ERROR "${FG_RED}ERROR${NC}: cardano-hw-cli not found in path or executable permission not set."
                          println ERROR "Please run '${FG_YELLOW}guild-deploy.sh -s w${NC}' to add hardware wallet support and install Vaccumlabs cardano-hw-cli, '${FG_YELLOW}guild-deploy.sh -h${NC}' shows all available options"
                          waitToProceed && continue
                        fi
                        if ! HWCLIversionCheck; then waitToProceed && continue; fi
                        ms_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_HW_PAY_SK_FILENAME}"
                        ms_payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
                        ms_stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_HW_STAKE_SK_FILENAME}"
                        ms_stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
                        if [[ -f ${ms_payment_sk_file} || -f ${ms_stake_sk_file} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: MultiSig payment and/or stake signing keys already exist!\n${stdout}"; waitToProceed && continue
                        fi
                        derivation_path_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DERIVATION_PATH_FILENAME}"
                        if ! getSavedDerivationPath "${derivation_path_file}"; then
                          getCustomDerivationPath || continue
                          echo "1852H/1815H/${acct_idx}H/x/${key_idx}" > "${derivation_path_file}"
                        fi
                        if ! unlockHWDevice "extract ${FG_LGRAY}MultiSig keys${NC}"; then waitToProceed && continue; fi
                        HW_DERIVATION_CMD=(
                          cardano-hw-cli address key-gen
                          --path 1854H/1815H/${acct_idx}H/0/${key_idx}
                          --path 1854H/1815H/${acct_idx}H/2/${key_idx}
                          --verification-key-file "${ms_payment_vk_file}"
                          --verification-key-file "${ms_stake_vk_file}"
                          --hw-signing-file "${ms_payment_sk_file}"
                          --hw-signing-file "${ms_stake_sk_file}"
                        )
                        println ACTION "${HW_DERIVATION_CMD[*]}"
                        if ! stdout=$("${HW_DERIVATION_CMD[@]}" 2>&1); then
                          println ERROR "\n${FG_RED}ERROR${NC}: failure during key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && continue
                        fi
                        jq '.description = "MultiSig Payment Hardware Verification Key"' "${ms_payment_vk_file}" > "${TMP_DIR}/$(basename "${ms_payment_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${ms_payment_vk_file}").tmp" "${ms_payment_vk_file}"
                        jq '.description = "MultiSig Stake Hardware Verification Key"' "${ms_stake_vk_file}" > "${TMP_DIR}/$(basename "${ms_stake_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${ms_stake_vk_file}").tmp" "${ms_stake_vk_file}"
                        ;;
                      *)
                        ms_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_SK_FILENAME}"
                        ms_payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
                        ms_stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_SK_FILENAME}"
                        ms_stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
                        if [[ -f ${ms_payment_sk_file} || -f ${ms_stake_sk_file} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: MultiSig payment and/or stake signing keys already exist!\n${stdout}"; waitToProceed && continue
                        fi
                        println DEBUG "Is selected wallet a CLI generated wallet or derived from mnemonic?"
                        select_opt "[c] CLI" "[m] Mnemonic"
                        case $? in
                          0) println ACTION "${CCLI} ${NETWORK_ERA} address key-gen --verification-key-file ${ms_payment_vk_file} --signing-key-file ${ms_payment_sk_file}"
                            if ! stdout=$(${CCLI} ${NETWORK_ERA} address key-gen --verification-key-file "${ms_payment_vk_file}" --signing-key-file "${ms_payment_sk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig payment key creation!\n${stdout}"; waitToProceed && continue
                            fi
                            println ACTION "${CCLI} ${NETWORK_ERA} stake-address key-gen --verification-key-file ${ms_stake_vk_file} --signing-key-file ${ms_stake_sk_file}"
                            if ! stdout=$(${CCLI} ${NETWORK_ERA} stake-address key-gen --verification-key-file "${ms_stake_vk_file}" --signing-key-file "${ms_stake_sk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig stake key creation!\n${stdout}"; waitToProceed && continue
                            fi
                            ;;
                          1) if ! cmdAvailable "bech32" &>/dev/null || \
                              ! cmdAvailable "cardano-address" &>/dev/null; then
                              println ERROR "${FG_RED}ERROR${NC}: bech32 and/or cardano-address not found in '\$PATH'"
                              println ERROR "Please run updated guild-deploy.sh and re-build/re-download cardano-node"
                              waitToProceed && continue
                            fi
                            getAnswerAnyCust mnemonic false "24 or 15 word mnemonic(space separated)"
                            echo
                            IFS=" " read -r -a words <<< "${mnemonic}"
                            if [[ ${#words[@]} -ne 24 ]] && [[ ${#words[@]} -ne 15 ]]; then
                              println ERROR "${FG_RED}ERROR${NC}: 24 or 15 words expected, found ${FG_RED}${#words[@]}${NC}"
                              unset mnemonic; unset words
                              waitToProceed && continue
                            fi
                            derivation_path_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DERIVATION_PATH_FILENAME}"
                            if ! getSavedDerivationPath "${derivation_path_file}"; then
                              getCustomDerivationPath || continue
                              echo "1852H/1815H/${acct_idx}H/x/${key_idx}" > "${derivation_path_file}"
                            fi
                            caddr_v="$(cardano-address -v | awk '{print $1}')"
                            [[ "${caddr_v}" == 3* ]] && caddr_arg="--with-chain-code" || caddr_arg=""
                            if ! root_prv=$(cardano-address key from-recovery-phrase Shelley <<< ${mnemonic}); then
                              unset mnemonic; unset words
                              waitToProceed && continue
                            fi
                            unset mnemonic; unset words
                            payment_xprv=$(cardano-address key child 1854H/1815H/${acct_idx}H/0/${key_idx} <<< ${root_prv})
                            stake_xprv=$(cardano-address key child 1854H/1815H/${acct_idx}H/2/${key_idx} <<< ${root_prv})
                            payment_xpub=$(cardano-address key public ${caddr_arg} <<< ${payment_xprv})
                            stake_xpub=$(cardano-address key public ${caddr_arg} <<< ${stake_xprv})
                            pes_key=$(bech32 <<< ${payment_xprv} | cut -b -128)$(bech32 <<< ${payment_xpub})
                            ses_key=$(bech32 <<< ${stake_xprv} | cut -b -128)$(bech32 <<< ${stake_xpub})
                            cat <<-EOF > "${ms_payment_sk_file}"
															{
																	"type": "PaymentExtendedSigningKeyShelley_ed25519_bip32",
																	"description": "MultiSig Payment Signing Key",
																	"cborHex": "5880${pes_key}"
															}
															EOF
                            cat <<-EOF > "${ms_stake_sk_file}"
															{
																	"type": "StakeExtendedSigningKeyShelley_ed25519_bip32",
																	"description": "MultiSig Stake Signing Key",
																	"cborHex": "5880${ses_key}"
															}
															EOF
                            println ACTION "${CCLI} ${NETWORK_ERA} key verification-key --signing-key-file ${ms_payment_sk_file} --verification-key-file ${TMP_DIR}/ms_payment.evkey"
                            if ! stdout=$(${CCLI} ${NETWORK_ERA} key verification-key --signing-key-file "${ms_payment_sk_file}" --verification-key-file "${TMP_DIR}/ms_payment.evkey" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig payment signing key extraction!\n${stdout}"; waitToProceed && continue
                            fi
                            println ACTION "${CCLI} ${NETWORK_ERA} key verification-key --signing-key-file ${ms_stake_sk_file} --verification-key-file ${TMP_DIR}/ms_stake.evkey"
                            if ! stdout=$(${CCLI} ${NETWORK_ERA} key verification-key --signing-key-file "${ms_stake_sk_file}" --verification-key-file "${TMP_DIR}/ms_stake.evkey" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig stake signing key extraction!\n${stdout}"; waitToProceed && continue
                            fi
                            println ACTION "${CCLI} ${NETWORK_ERA} key non-extended-key --extended-verification-key-file ${TMP_DIR}/ms_payment.evkey --verification-key-file ${ms_payment_vk_file}"
                            if ! stdout=$(${CCLI} ${NETWORK_ERA} key non-extended-key --extended-verification-key-file "${TMP_DIR}/ms_payment.evkey" --verification-key-file "${ms_payment_vk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig payment verification key extraction!\n${stdout}"; waitToProceed && continue
                            fi
                            println ACTION "${CCLI} ${NETWORK_ERA} key non-extended-key --extended-verification-key-file ${TMP_DIR}/ms_stake.evkey --verification-key-file ${ms_stake_vk_file}"
                            if ! stdout=$(${CCLI} ${NETWORK_ERA} key non-extended-key --extended-verification-key-file "${TMP_DIR}/ms_stake.evkey" --verification-key-file "${ms_stake_vk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig stake verification key extraction!\n${stdout}"; waitToProceed && continue
                            fi
                            ;;
                        esac
                        ;;
                    esac
                    chmod 600 "${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}"*
                    echo
                    getCredentials ${wallet_name}
                    println "Wallet   : ${FG_GREEN}${wallet_name}${NC}"
                    println "MultiSig Credentials"
                    println "Payment  : ${ms_pay_cred}"
                    println "Stake    : ${ms_stake_cred}"
                    waitToProceed && continue
                    ;; ###################################################################
                esac # advanced >> MultiSig sub OPERATION
              done # MultiSig loop
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
              waitToProceed && continue
              ;; ###################################################################
          esac # advanced sub OPERATION
        done # Advanced loop
        ;; ###################################################################
    esac # main OPERATION
  done # main loop
}

##############################################################

main "$@"
