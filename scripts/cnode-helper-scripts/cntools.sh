#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2154,SC2034,SC2012,SC2140

########## Global tasks ###########################################

# General exit handler
cleanup() {
  sleep 0.1
  exec 1>&6 2>&7 3>&- 6>&- 7>&- 8>&- 9>&- # Restore stdout/stderr and close tmp file descriptors
  [[ -n $1 ]] && err=$1 || err=$?
  [[ $err -eq 0 ]] && clear
  [[ -n ${exit_msg} ]] && echo -e "\n${exit_msg}\n" || echo -e "\nCNTools terminated, cleaning up...\n"
  tput cnorm # restore cursor
  tput sgr0  # turn off all attributes
  exit $err
}
trap cleanup HUP INT TERM
trap 'stty echo' EXIT

# Command     : myExit [exit code] [message]
# Description : gracefully handle an exit and restore terminal to original state
myExit() {
  exit_msg="$2"
  cleanup "$1"
}

clear

usage() {
  cat <<EOF
Usage: $(basename "$0") [-o] [-b <branch name>]
CNTools - The Cardano SPOs best friend

-o    Activate offline mode - run CNTools in offline mode without node access, a limited set of functions available
-b    Run CNTools and look for updates on alternate branch instead of master of guild repository (only for testing/development purposes)
EOF
}

CNTOOLS_MODE="CONNECTED"
PARENT="$(dirname $0)"
[[ -f "${PARENT}"/.env_branch ]] && BRANCH="$(cat "${PARENT}"/.env_branch)" || BRANCH="master"

while getopts :ob: opt; do
  case ${opt} in
    o ) CNTOOLS_MODE="OFFLINE" ;;
    b ) BRANCH=${OPTARG}; echo "${BRANCH}" > "${PARENT}"/.env_branch ;;
    \? ) myExit 1 "$(usage)" ;;
    esac
done
shift $((OPTIND -1))

URL_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}"
URL="${URL_RAW}/scripts/cnode-helper-scripts"
URL_DOCS="${URL_RAW}/docs/Scripts"

# env version check
if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
  if curl -s -m 10 -o "${PARENT}"/env.tmp ${URL}/env 2>/dev/null && [[ -f "${PARENT}"/env.tmp ]]; then
    if [[ -f "${PARENT}"/env ]]; then
      if [[ $(grep "_HOME=" "${PARENT}"/env) =~ ^#?([^[:space:]]+)_HOME ]]; then
        vname=$(tr '[:upper:]' '[:lower:]' <<< ${BASH_REMATCH[1]})
        sed -e "s@/opt/cardano/[c]node@/opt/cardano/${vname}@g" -e "s@[C]NODE_HOME@${BASH_REMATCH[1]}_HOME@g" -i "${PARENT}"/env.tmp
      else
        myExit 1 "\nUpdate for env file failed! Please use prereqs.sh to force an update or manually download $(basename $0) + env from GitHub\n"
      fi
      TEMPL_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env)
      TEMPL2_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env.tmp)
      if [[ "$(echo ${TEMPL_CMD} | sha256sum)" != "$(echo ${TEMPL2_CMD} | sha256sum)" ]]; then
        echo -e "\nThe static content from env file does not match with guild-operators repository, do you want to download the updated file? [y|n]"
        read -r -n 1 -s update
        case ${update} in
          [yY])
            cp "${PARENT}"/env "${PARENT}/env_bkp$(date +%s)"
            STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/env)
            printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL2_CMD" > "${PARENT}"/env.tmp
            mv "${PARENT}"/env.tmp "${PARENT}"/env
            echo -e "\nUpdate to env file applied successfully!\n\nPress any key to continue!"
            read -r -n 1 -s wait
            ;;
          *) : ;; # ignore
        esac
      fi
    else
      mv "${PARENT}"/env.tmp "${PARENT}"/env
      myExit 0 "Common env file downloaded: ${PARENT}/env\n\
This is a mandatory prerequisite, please set variables accordingly in User Variables section in the env file and restart CNTools\n"
    fi
  fi
  rm -f "${PARENT}"/env.tmp
fi
[[ ${CNTOOLS_MODE} = "CONNECTED" ]] && env_mode="" || env_mode="offline"
if ! . "${PARENT}"/env ${env_mode}; then
  myExit 1 "\nERROR: CNTools failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub\n"
fi

# get cntools config parameters
. "${PARENT}"/cntools.config

# get helper functions from library file
. "${PARENT}"/cntools.library

# create temporary directory if missing & remove lockfile if it exist
mkdir -p "${TMP_FOLDER}" # Create if missing
if [[ ! -d "${TMP_FOLDER}" ]]; then
  myExit 1 "${FG_RED}ERROR${NC}: Failed to create directory for temporary files:\n${TMP_FOLDER}"
fi

archiveLog # archive current log and cleanup log archive folder

exec 6>&1 # Link file descriptor #6 with normal stdout.
exec 7>&2 # Link file descriptor #7 with normal stderr.
[[ -n ${CNTOOLS_LOG} ]] && exec > >( tee >( while read -r line; do logln "INFO" "${line}"; done ) )
[[ -n ${CNTOOLS_LOG} ]] && exec 2> >( tee >( while read -r line; do logln "ERROR" "${line}"; done ) >&2 )
[[ -n ${CNTOOLS_LOG} ]] && exec 3> >( tee >( while read -r line; do logln "DEBUG" "${line}"; done ) >&6 )
exec 8>&1 # Link file descriptor #8 with custom stdout.
exec 9>&2 # Link file descriptor #9 with custom stderr.

# check for required command line tools
if ! need_cmd "curl" || \
   ! need_cmd "jq" || \
   ! need_cmd "bc" || \
   ! need_cmd "sed" || \
   ! need_cmd "awk" || \
   ! need_cmd "column" || \
   ! protectionPreRequisites; then waitForInput "Missing one or more of the required command line tools, press any key to exit"; myExit 1
fi

if [[ "$CNTOOLS_PATCH_VERSION" -eq 999  ]]; then
  # CNTools was updated using special 999 patch tag, apply correct version in cntools.library and update variables already sourced
  sed -i "s/CNTOOLS_MAJOR_VERSION=[[:digit:]]\+/CNTOOLS_MAJOR_VERSION=$((++CNTOOLS_MAJOR_VERSION))/" "${PARENT}/cntools.library"
  sed -i "s/CNTOOLS_MINOR_VERSION=[[:digit:]]\+/CNTOOLS_MINOR_VERSION=0/" "${PARENT}/cntools.library"
  sed -i "s/CNTOOLS_PATCH_VERSION=[[:digit:]]\+/CNTOOLS_PATCH_VERSION=0/" "${PARENT}/cntools.library"
  # CNTOOLS_MAJOR_VERSION variable already updated in sed replace command
  CNTOOLS_MINOR_VERSION=0
  CNTOOLS_PATCH_VERSION=0
  CNTOOLS_VERSION="${CNTOOLS_MAJOR_VERSION}.${CNTOOLS_MINOR_VERSION}.${CNTOOLS_PATCH_VERSION}"
fi

# Do some checks when run in connected mode
if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
  # check to see if there are any updates available
  clear
  println "DEBUG" "CNTools version check...\n"
  if curl -s -m ${CURL_TIMEOUT} -o "${TMP_FOLDER}"/cntools.library "${URL}/cntools.library" && [[ -f "${TMP_FOLDER}"/cntools.library ]]; then
    GIT_MAJOR_VERSION=$(grep -r ^CNTOOLS_MAJOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    GIT_MINOR_VERSION=$(grep -r ^CNTOOLS_MINOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    GIT_PATCH_VERSION=$(grep -r ^CNTOOLS_PATCH_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    if [[ "$GIT_PATCH_VERSION" -eq 999  ]]; then
      ((GIT_MAJOR_VERSION++))
      GIT_MINOR_VERSION=0
      GIT_PATCH_VERSION=0
    fi
    GIT_VERSION="${GIT_MAJOR_VERSION}.${GIT_MINOR_VERSION}.${GIT_PATCH_VERSION}"
    if ! versionCheck "${GIT_VERSION}" "${CNTOOLS_VERSION}"; then
      println "DEBUG" "A new version of CNTools is available"
      echo
      println "DEBUG" "Installed Version : ${CNTOOLS_VERSION}"
      println "DEBUG" "Available Version : ${FG_GREEN}${GIT_VERSION}${NC}"
      println "DEBUG" "\nGo to Update section for upgrade\n\nAlternately, follow https://cardano-community.github.io/guild-operators/#/basics?id=pre-requisites to update cntools as well alongwith any other files"
      waitForInput "press any key to proceed"
    else
      # check if CNTools was recently updated, if so show whats new
      if curl -s -m ${CURL_TIMEOUT} -o "${TMP_FOLDER}"/cntools-changelog.md "${URL_DOCS}/cntools-changelog.md"; then
        if ! cmp -s "${TMP_FOLDER}"/cntools-changelog.md "${PARENT}/cntools-changelog.md"; then
          # Latest changes not shown, show whats new and copy changelog
          clear 
          exec >&6 # normal stdout
          sleep 0.1
          if [[ ! -f "${PARENT}/cntools-changelog.md" ]]; then 
            # special case for first installation or 5.0.0 upgrade, print release notes until previous major version
            println "OFF" "~ CNTools - What's New ~\n\n" "$(sed -n "/\[${CNTOOLS_MAJOR_VERSION}\.${CNTOOLS_MINOR_VERSION}\.${CNTOOLS_PATCH_VERSION}\]/,/\[$((CNTOOLS_MAJOR_VERSION-1))\.[0-9]\.[0-9]\]/p" "${TMP_FOLDER}"/cntools-changelog.md | head -n -2)" | less -X
          else
            # print release notes from current until previously installed version
            [[ $(cat "${PARENT}/cntools-changelog.md") =~ \[([[:digit:]])\.([[:digit:]])\.([[:digit:]])\] ]]
            cat <(println "OFF" "~ CNTools - What's New ~\n") <(awk "1;/\[${BASH_REMATCH[1]}\.${BASH_REMATCH[2]}\.${BASH_REMATCH[3]}\]/{exit}" "${TMP_FOLDER}"/cntools-changelog.md | head -n -2 | tail -n +7) <(echo -e "\n [Press 'q' to quit and proceed to CNTools main menu]\n") | less -X
          fi
          exec >&8 # custom stdout
          cp "${TMP_FOLDER}"/cntools-changelog.md "${PARENT}/cntools-changelog.md"
        fi
      else
        println "ERROR" "\n${FG_RED}ERROR${NC}: failed to download changelog from GitHub!"
        waitForInput "press any key to proceed"
      fi
    fi
  else
    println "ERROR" "\n${FG_RED}ERROR${NC}: failed to download cntools.library from GitHub, unable to perform version check!"
    waitForInput "press any key to proceed"
  fi

  # Validate protocol parameters
  if grep -q "Network.Socket.connect" <<< "${PROT_PARAMS}"; then
    myExit 1 "${FG_YELLOW}WARN${NC}: node socket path wrongly configured or node not running, please verify that socket set in env file match what is used to run the node\n\n\
${FG_BLUE}INFO${NC}: re-run CNTools in offline mode with -o parameter if you want to access CNTools with limited functionality"
  elif [[ -z "${PROT_PARAMS}" ]] || ! jq -er . <<< "${PROT_PARAMS}" &>/dev/null; then
    myExit 1 "${FG_YELLOW}WARN${NC}: failed to query protocol parameters, ensure your node is running with correct genesis (the node needs to be in sync to 1 epoch after the hardfork)\n\n\
Error message: ${PROT_PARAMS}\n\n\
${FG_BLUE}INFO${NC}: re-run CNTools in offline mode with -o parameter if you want to access CNTools with limited functionality"
  fi
  echo "${PROT_PARAMS}" > "${TMP_FOLDER}"/protparams.json
fi

# check if there are pools in need of KES key rotation
clear
kes_rotation_needed="no"
while IFS= read -r -d '' pool; do
  if [[ -f "${pool}/${POOL_CURRENT_KES_START}" ]]; then
    kesExpiration "$(cat "${pool}/${POOL_CURRENT_KES_START}")"
    if [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
      kes_rotation_needed="yes"
      println "\n** WARNING **\nPool ${FG_GREEN}$(basename ${pool})${NC} in need of KES key rotation"
      if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
        println "DEBUG" "${FG_RED}Keys expired!${NC} : ${FG_RED}$(showTimeLeft ${expiration_time_sec_diff:1})${NC} ago"
      else
        println "DEBUG" "Remaining KES periods : ${FG_RED}${remaining_kes_periods}${NC}"
        println "DEBUG" "Time left             : ${FG_RED}$(showTimeLeft ${expiration_time_sec_diff})${NC}"
      fi
    elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
      kes_rotation_needed="yes"
      println "DEBUG" "\nPool ${FG_GREEN}$(basename ${pool})${NC} soon in need of KES key rotation"
      println "DEBUG" "Remaining KES periods : ${FG_YELLOW}${remaining_kes_periods}${NC}"
      println "DEBUG" "Time left             : ${FG_YELLOW}$(showTimeLeft ${expiration_time_sec_diff})${NC}"
    fi
  fi
done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
[[ ${kes_rotation_needed} = "yes" ]] && waitForInput "press any key to proceed"

# Verify if the combinator network is already on shelley and if so, the epoch of transition
if [[ "${PROTOCOL}" == "Cardano" ]]; then
  shelleyTransitionEpoch=$(cat "${SHELLEY_TRANS_FILENAME}" 2>/dev/null)
  if [[ -z "${shelleyTransitionEpoch}" ]]; then
    clear
    if [[ "${NETWORK_IDENTIFIER}" == "--mainnet" ]]; then
      shelleyTransitionEpoch="208"
    elif [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
      getNodeMetrics
      epoch=$(jq '.cardano.node.ChainDB.metrics.epoch.int.val //0' <<< "${node_metrics}")
      slot_in_epoch=$(jq '.cardano.node.ChainDB.metrics.slotInEpoch.int.val //0' <<< "${node_metrics}")
      slot_num=$(jq '.cardano.node.ChainDB.metrics.slotNum.int.val //0' <<< "${node_metrics}")
      calc_slot=0
      byron_epochs=${epoch}
      shelley_epochs=0
      while [[ ${byron_epochs} -ge 0 ]]; do
        calc_slot=$(( (byron_epochs*BYRON_EPOCH_LENGTH) + (shelley_epochs*EPOCH_LENGTH) + slot_in_epoch ))
        [[ ${calc_slot} -eq ${slot_num} ]] && break
        ((byron_epochs--))
        ((shelley_epochs++))
      done
      node_sync="NODE SYNC: Epoch[${epoch}] - Slot in Epoch[${slot_in_epoch}] - Slot[${slot_num}]\n"
      if [[ ${calc_slot} -ne ${slot_num} ]]; then
        myExit 1 "${FG_YELLOW}WARN${NC}: Failed to calculate shelley transition epoch\n\n${node_sync}"
      elif [[ ${shelley_epochs} -eq 0 ]]; then
        myExit 1 "${FG_YELLOW}WARN${NC}: The network has not reached the hard fork from Byron to shelley, please wait to use CNTools until your node is in shelley era\n\n${node_sync}"
      else
        shelleyTransitionEpoch=${byron_epochs}
      fi
    else
      myExit 1 "${FG_YELLOW}WARN${NC}: Offline mode enabled and config set to TestNet, please manually create and set shelley transition epoch:\nE.g. : ${FG_CYAN}echo 74 > \"${SHELLEY_TRANS_FILENAME}\"${NC}"
    fi
    echo "${shelleyTransitionEpoch}" > "${SHELLEY_TRANS_FILENAME}"
  fi
fi

###################################################################

function main {

while true; do # Main loop

# Start with a clean slate after each completed or canceled command excluding .dialogrc from purge
find "${TMP_FOLDER:?}" -type f -not \( -name 'protparams.json' -o -name '.dialogrc' -o -name "offline_tx*" -o -name "*_cntools_backup*" \) -delete

clear
println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
  println "$(printf " >> CNTools v%s - ${FG_GREEN}%s${NC} << %$((84-20-${#CNTOOLS_VERSION}-${#CNTOOLS_MODE}))s" "${CNTOOLS_VERSION}" "${CNTOOLS_MODE}" "A Guild Operators collaboration")"
else
  println "$(printf " >> CNTools v%s - ${FG_CYAN}%s${NC} << %$((84-20-${#CNTOOLS_VERSION}-${#CNTOOLS_MODE}))s" "${CNTOOLS_VERSION}" "${CNTOOLS_MODE}" "A Guild Operators collaboration")"
fi
println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
println "OFF" " Main Menu\n\n"\
" ) Wallet      - create, show, remove and protect wallets\n"\
" ) Funds       - send, withdraw and delegate\n"\
" ) Pool        - pool creation and management\n"\
" ) Transaction - Witness, Sign and Submit a cold transaction (hybrid/offline mode)\n"\
" ) Metadata    - Post metadata on-chain (e.g voting)\n"\
" ) Blocks      - show core node leader slots\n"\
" ) Update      - update cntools script and library config files\n"\
" ) Backup      - backup & restore of wallet/pool/config\n"\
" ) Refresh     - reload home screen content\n"\
"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
println "DEBUG" "$(printf "%84s" "Epoch $(getEpoch) - $(timeUntilNextEpoch) until next")"
if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
  println "DEBUG" " What would you like to do?"
else
  tip_diff=$(getSlotTipDiff)
  slot_interval=$(slotInterval)
  if [[ ${tip_diff} -le ${slot_interval} ]]; then
    println "DEBUG" "$(printf " What would you like to do? %$((84-29-${#tip_diff}-3))s ${FG_GREEN}%s${NC}" "Node Sync:" "${tip_diff} :)")"
  elif [[ ${tip_diff} -le $(( slot_interval * 2 )) ]]; then
    println "DEBUG" "$(printf " What would you like to do? %$((84-29-${#tip_diff}-3))s ${FG_YELLOW}%s${NC}" "Node Sync:" "${tip_diff} :|")"
  else
    println "DEBUG" "$(printf " What would you like to do? %$((84-29-${#tip_diff}-3))s ${FG_RED}%s${NC}" "Node Sync:" "${tip_diff} :(")"
  fi
fi
echo
select_opt "[w] Wallet" "[f] Funds" "[p] Pool" "[t] Transaction" "[m] Metadata" "[b] Blocks" "[u] Update" "[z] Backup & Restore" "[r] Refresh" "[q] Quit"
case $? in
  0) OPERATION="wallet" ;;
  1) OPERATION="funds" ;;
  2) OPERATION="pool" ;;
  3) OPERATION="transaction" ;;
  4) OPERATION="metadata" ;;
  5) OPERATION="blocks" ;;
  6) OPERATION="update" ;;
  7) OPERATION="backup" ;;
  8) continue ;;
  9) myExit 0 "CNTools closed!" ;;
esac

case $OPERATION in
  wallet)

  clear
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println " >> WALLET"
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println "OFF" " Wallet Management\n\n"\
" ) New         - create a new wallet\n"\
" ) Import      - import a Daedalus/Yoroi 24/25 mnemonic or Ledger/Trezor HW wallet\n"\
" ) Register    - register a wallet on chain\n"\
" ) De-Register - De-Register (retire) a registered wallet\n"\
" ) List        - list all available wallets in a compact view\n"\
" ) Show        - show detailed view of a specific wallet\n"\
" ) Remove      - remove a wallet\n"\
" ) Decrypt     - remove write protection and decrypt wallet\n"\
" ) Encrypt     - encrypt wallet keys and make all files immutable\n"\
"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println "DEBUG" " Select Wallet operation\n"
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
    9) continue ;;
  esac

  case $SUBCOMMAND in
    new)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> WALLET >> NEW"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    
    sleep 0.1 && read -r -p "Name of new wallet: " wallet_name 2>&6 && println "LOG" "Name of new wallet: ${wallet_name}"
    # Remove unwanted characters from wallet name
    wallet_name=${wallet_name//[^[:alnum:]]/_}
    if [[ -z "${wallet_name}" ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: Empty wallet name, please retry!"
      waitForInput && continue
    fi
    echo
    if ! mkdir -p "${WALLET_FOLDER}/${wallet_name}"; then
      println "ERROR" "${FG_RED}ERROR${NC}: Failed to create directory for wallet:\n${WALLET_FOLDER}/${wallet_name}"
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

    println "ACTION" "${CCLI} address key-gen --verification-key-file \"${payment_vk_file}\" --signing-key-file \"${payment_sk_file}\""
    ${CCLI} address key-gen --verification-key-file "${payment_vk_file}" --signing-key-file "${payment_sk_file}"
    println "ACTION" "${CCLI} stake-address key-gen --verification-key-file \"${stake_vk_file}\" --signing-key-file \"${stake_sk_file}\""
    ${CCLI} stake-address key-gen --verification-key-file "${stake_vk_file}" --signing-key-file "${stake_sk_file}"
    chmod 700 ${WALLET_FOLDER}/${wallet_name}/*
    getBaseAddress ${wallet_name}
    getPayAddress ${wallet_name}
    getRewardAddress ${wallet_name}

    println "New Wallet          : ${FG_GREEN}${wallet_name}${NC}"
    println "Address             : ${base_addr}"
    println "Enterprise Address  : ${pay_addr}"
    println "DEBUG" "\nYou can now send and receive Ada using the above addresses."
    println "DEBUG" "Note that Enterprise Address will not take part in staking."
    println "DEBUG" "Wallet will be automatically registered on chain if you\nchoose to delegate or pledge wallet when registering a stake pool."
    
    waitForInput && continue

    ;; ###################################################################
    
    import)
    
    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> WALLET >> IMPORT"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println "OFF" " Wallet Import\n\n"\
" ) Mnemonic  - Daedalus/Yoroi 24 or 25 word mnemonic\n"\
" ) HW Wallet - Ledger/Trezor hardware wallet\n"\
"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println "DEBUG" " Select Wallet operation\n"
    select_opt "[m] Mnemonic" "[w] HW Wallet" "[h] Home"
    case $? in
      0) SUBCOMMAND="mnemonic" ;;
      1) SUBCOMMAND="hardware" ;;
      2) continue ;;
    esac

    case $SUBCOMMAND in
      mnemonic)

      clear
      println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      println " >> WALLET >> IMPORT >> MNEMONIC"
      println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo
      
      if ! need_cmd "bech32" || \
         ! need_cmd "cardano-address"; then
        println "ERROR" "${FG_RED}ERROR${NC}: cardano-address and/or bech32 executables not found in path!"
        println "ERROR" "Please run updated prereqs.sh and re-build cardano-node"
        waitForInput && continue
      fi
      
      sleep 0.1 && read -r -p "Name of imported wallet: " wallet_name 2>&6 && println "LOG" "Name of imported wallet: ${wallet_name}"
      # Remove unwanted characters from wallet name
      wallet_name=${wallet_name//[^[:alnum:]]/_}
      if [[ -z "${wallet_name}" ]]; then
        println "ERROR" "${FG_RED}ERROR${NC}: Empty wallet name, please retry!"
        waitForInput && continue
      fi
      echo
      if ! mkdir -p "${WALLET_FOLDER}/${wallet_name}"; then
        println "ERROR" "${FG_RED}ERROR${NC}: Failed to create directory for wallet:\n${WALLET_FOLDER}/${wallet_name}"
        waitForInput && continue
      fi
      
      if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -type f -print0 | wc -c) -gt 0 ]]; then
        println "${FG_RED}WARN${NC}: A wallet ${FG_GREEN}$wallet_name${NC} already exists"
        println "      Choose another name or delete the existing one"
        waitForInput && continue
      fi
      
      sleep 0.1 && read -r -p "24 or 15 word mnemonic(space separated): " mnemonic 2>&6
      echo
      IFS=" " read -r -a words <<< "${mnemonic}"
      if [[ ${#words[@]} -ne 24 ]] && [[ ${#words[@]} -ne 15 ]]; then
        println "ERROR" "${FG_RED}ERROR${NC}: 24 or 15 words expected, found ${FG_RED}${#words[@]}${NC}"
        echo && safeDel "${WALLET_FOLDER}/${wallet_name}"
        waitForInput && continue
      fi
      
      payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
      payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
      stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"  
      
      if ! root_prv=$(cardano-address key from-recovery-phrase Shelley <<< ${mnemonic}); then
        echo && safeDel "${WALLET_FOLDER}/${wallet_name}"
        waitForInput && continue
      fi
      payment_xprv=$(cardano-address key child 1852H/1815H/0H/0/0 <<< ${root_prv})
      stake_xprv=$(cardano-address key child 1852H/1815H/0H/2/0 <<< ${root_prv})
      
      payment_xpub=$(cardano-address key public <<< ${payment_xprv})
      stake_xpub=$(cardano-address key public <<< ${stake_xprv})
      [[ "${NETWORKID}" = "Mainnet" ]] && network_tag=1 || network_tag=0
      base_addr_candidate=$(cardano-address address delegation ${stake_xpub} <<< "$(cardano-address address payment --network-tag ${network_tag} <<< ${payment_xpub})")
      if [[ "${NETWORKID}" = "Testnet" ]]; then
        println "LOG" "TestNet, converting address to 'addr_test'"
        base_addr_candidate=$(bech32 addr_test <<< ${base_addr_candidate})
      fi
      println "LOG" "Base address candidate = ${base_addr_candidate}"
      println "LOG" "Address Inspection:\n$(cardano-address address inspect <<< ${base_addr_candidate})"
      
      pes_key=$(bech32 <<< ${payment_xprv} | cut -b -128)$(bech32 <<< ${payment_xpub})
      ses_key=$(bech32 <<< ${stake_xprv} | cut -b -128)$(bech32 <<< ${stake_xpub})
      
      cat << EOF > "${payment_sk_file}"
{
    "type": "PaymentExtendedSigningKeyShelley_ed25519_bip32",
    "description": "Payment Signing Key",
    "cborHex": "5880${pes_key}"
}
EOF
    
      cat << EOF > "${stake_sk_file}"
{
    "type": "StakeExtendedSigningKeyShelley_ed25519_bip32",
    "description": "",
    "cborHex": "5880${ses_key}"
}
EOF
      println "ACTION" "${CCLI} key verification-key --signing-key-file \"${payment_sk_file}\" --verification-key-file \"${TMP_FOLDER}/payment.evkey\""
      ${CCLI} key verification-key --signing-key-file "${payment_sk_file}" --verification-key-file "${TMP_FOLDER}/payment.evkey"
      println "ACTION" "${CCLI} key verification-key --signing-key-file \"${stake_sk_file}\" --verification-key-file \"${TMP_FOLDER}/stake.evkey\""
      ${CCLI} key verification-key --signing-key-file "${stake_sk_file}" --verification-key-file "${TMP_FOLDER}/stake.evkey"

      println "ACTION" "${CCLI} key non-extended-key --extended-verification-key-file \"${TMP_FOLDER}/payment.evkey\" --verification-key-file \"${payment_vk_file}\""
      ${CCLI} key non-extended-key --extended-verification-key-file "${TMP_FOLDER}/payment.evkey" --verification-key-file "${payment_vk_file}"
      println "ACTION" "${CCLI} key non-extended-key --extended-verification-key-file \"${TMP_FOLDER}/stake.evkey\" --verification-key-file \"${stake_vk_file}\""
      ${CCLI} key non-extended-key --extended-verification-key-file "${TMP_FOLDER}/stake.evkey" --verification-key-file "${stake_vk_file}"
      chmod 700 ${WALLET_FOLDER}/${wallet_name}/*

      getBaseAddress ${wallet_name}
      getPayAddress ${wallet_name}
      getRewardAddress ${wallet_name}
      
      if [[ ${base_addr} != "${base_addr_candidate}" ]]; then
        println "ERROR" "${FG_RED}ERROR${NC}: base address generated doesn't match base address candidate."
        println "ERROR" "base_addr[${FG_CYAN}${base_addr}${NC}]\n!=\nbase_addr_candidate[${FG_CYAN}${base_addr_candidate}${NC}]"
        println "ERROR" "Create a GitHub issue and include log file from failed CNTools session."
        echo && safeDel "${WALLET_FOLDER}/${wallet_name}"
        waitForInput && continue
      fi
      
      echo
      println "Wallet Imported     : ${FG_GREEN}${wallet_name}${NC}"
      println "Address             : ${base_addr}"
      println "Enterprise Address  : ${pay_addr}"
      echo
      println "DEBUG" "You can now send and receive Ada using the above addresses. Note that Enterprise Address will not take part in staking"
      println "DEBUG" "Wallet will be automatically registered on chain if you choose to delegate or pledge wallet when registering a stake pool"
      echo
      println "DEBUG" "${FG_YELLOW}Using a mnemonic imported wallet in CNTools comes with a few limitations${NC}"
      echo
      println "DEBUG" "Only the first address in the HD wallet is extracted and because of this the following apply:"
      println "DEBUG" " ${FG_CYAN}>${NC} Address above should match the first address seen in Daedalus/Yoroi, please verify!!!"
      println "DEBUG" " ${FG_CYAN}>${NC} If restored wallet contain funds since before, send all Ada through Daedalus/Yoroi to address shown in CNTools"
      println "DEBUG" " ${FG_CYAN}>${NC} Only use receive address shown in CNTools"
      println "DEBUG" " ${FG_CYAN}>${NC} Only spend Ada from CNTools, if spent through Daedalus/Yoroi balance seen in CNTools wont match"
      echo
      println "DEBUG" "Some of the advantages of using a mnemonic imported wallet instead of CLI are:"
      println "DEBUG" " ${FG_CYAN}>${NC} Wallet can be restored from saved 24 or 15 word mnemonic if keys are lost/deleted"
      println "DEBUG" " ${FG_CYAN}>${NC} Track rewards in Daedalus/Yoroi"
      echo
      println "DEBUG" "Please read more about HD wallets at:"
      println "DEBUG" "https://cardano-community.github.io/support-faq/#/wallets?id=heirarchical-deterministic-hd-wallets"
      
      waitForInput && continue

      ;; ###################################################################
      
      hardware)

      clear
      println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      println " >> WALLET >> IMPORT >> HARDWARE WALLET"
      println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo
      
      println "DEBUG" "Supported HW wallets: Ledger S, Ledger X, Trezor Model T"
      println "Is your hardware wallet one of these models?"
      select_opt "[y] Yes" "[n] No"
      case $? in
        0) : ;; # do nothing
        1) waitForInput "Unsupported hardware wallet, press any key to return home" && continue ;;
      esac
      echo
      
      if ! need_cmd "cardano-hw-cli"; then
        println "ERROR" "${FG_RED}ERROR${NC}: cardano-hw-cli executable not found in path!"
        println "ERROR" "Please run '${FG_CYAN}prereqs.sh -w${NC}' to add hardware wallet support and install Vaccumlabs cardano-hw-cli, '${FG_CYAN}prereqs.sh -h${NC}' shows all available options"
        waitForInput && continue
      fi
      
      sleep 0.1 && read -r -p "Name of imported wallet: " wallet_name 2>&6 && println "LOG" "Name of imported wallet: ${wallet_name}"
      # Remove unwanted characters from wallet name
      wallet_name=${wallet_name//[^[:alnum:]]/_}
      if [[ -z "${wallet_name}" ]]; then
        println "ERROR" "${FG_RED}ERROR${NC}: Empty wallet name, please retry!"
        waitForInput && continue
      fi
      
      if ! mkdir -p "${WALLET_FOLDER}/${wallet_name}"; then
        println "ERROR" "${FG_RED}ERROR${NC}: Failed to create directory for wallet:\n${WALLET_FOLDER}/${wallet_name}"
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
      
      if ! unlockHWDevice "extract ${FG_CYAN}payment keys${NC}"; then continue; fi
      println "ACTION" "cardano-hw-cli shelley address key-gen --path 1852H/1815H/0H/0/0 --verification-key-file \"${payment_vk_file}\" --hw-signing-file \"${payment_sk_file}\""
      output=$(cardano-hw-cli shelley address key-gen --path 1852H/1815H/0H/0/0 --verification-key-file "${payment_vk_file}" --hw-signing-file "${payment_sk_file}" 2>&1)
      [[ -n ${output} ]] && println "ERROR" "${output}\n${FG_RED}ERROR${NC}: failure during payment key extraction!" && waitForInput && continue
      jq '.description = "Payment Hardware Verification Key"' "${payment_vk_file}" > "${TMP_FOLDER}/$(basename "${payment_vk_file}").tmp" && mv -f "${TMP_FOLDER}/$(basename "${payment_vk_file}").tmp" "${payment_vk_file}"
      println "DEBUG" "${FG_BLUE}INFO${NC}: repeat and follow instructions on hardware device to extract the ${FG_CYAN}stake keys${NC}"
      println "ACTION" "cardano-hw-cli shelley address key-gen --path 1852H/1815H/0H/2/0 --verification-key-file \"${stake_vk_file}\" --hw-signing-file \"${stake_sk_file}\""
      output=$(cardano-hw-cli shelley address key-gen --path 1852H/1815H/0H/2/0 --verification-key-file "${stake_vk_file}" --hw-signing-file "${stake_sk_file}" 2>&1)
      [[ -n ${output} ]] && println "ERROR" "${output}\n${FG_RED}ERROR${NC}: failure during stake key extraction!" && waitForInput && continue
      jq '.description = "Stake Hardware Verification Key"' "${stake_vk_file}" > "${TMP_FOLDER}/$(basename "${stake_vk_file}").tmp" && mv -f "${TMP_FOLDER}/$(basename "${stake_vk_file}").tmp" "${stake_vk_file}"
      
      getBaseAddress ${wallet_name}
      getPayAddress ${wallet_name}
      getRewardAddress ${wallet_name}
      
      echo
      println "HW Wallet Imported  : ${FG_GREEN}${wallet_name}${NC}"
      println "Address             : ${base_addr}"
      println "Enterprise Address  : ${pay_addr}"
      echo
      println "DEBUG" "You can now send and receive Ada using the above addresses. Note that Enterprise Address will not take part in staking"
      echo
      println "DEBUG" "All transaction signing is now done through hardware device, please follow directions in both CNTools and the device display!"
      println "DEBUG" "${FG_YELLOW}Using an imported hardware wallet in CNTools comes with a few limitations${NC}"
      echo
      println "DEBUG" "Most operations like delegation and sending funds is seamless. For pool registration/modification however the following apply:"
      println "DEBUG" " ${FG_CYAN}>${NC} Pool owner has to be a CLI wallet with enough funds to pay for pool registration deposit and transaction fee"
      println "DEBUG" " ${FG_CYAN}>${NC} Add the hardware wallet containing the pledge as a multi-owner to the pool"
      println "DEBUG" " ${FG_CYAN}>${NC} The hardware wallet can be used as the reward wallet, but has to be included as a multi-owner if it should be counted to pledge"
      echo
      println "DEBUG" "Only the first address in the HD wallet is extracted and because of this the following apply if also synced with Daedalus/Yoroi:"
      println "DEBUG" " ${FG_CYAN}>${NC} Address above should match the first address seen in Daedalus/Yoroi, please verify!!!"
      println "DEBUG" " ${FG_CYAN}>${NC} If restored wallet contain funds since before, send all Ada through Daedalus/Yoroi to address shown in CNTools"
      println "DEBUG" " ${FG_CYAN}>${NC} Only use the address shown in CNTools to receive funds"
      println "DEBUG" " ${FG_CYAN}>${NC} Only spend Ada from CNTools, if spent through Daedalus/Yoroi balance seen in CNTools wont match"
      
      waitForInput && continue
      
      ;; ###################################################################
      
    esac

    ;; ###################################################################
    
    register)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> WALLET >> REGISTER"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
    
    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo
    
    println "DEBUG" "# Select wallet to register (only non-registered wallets shown)"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "non-reg" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
      getWalletType ${wallet_name}
      case $? in
        2) println "ERROR" "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
        3) println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
      esac
    else
      if ! selectWallet "non-reg" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
      getWalletType ${wallet_name}
    fi
    
    getBaseAddress ${wallet_name}
    getBalance ${base_addr}

    if [[ ${lovelace} -gt 0 ]]; then
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        println "DEBUG" "$(printf "%s\t${FG_CYAN}%s${NC} Ada" "Funds in wallet:"  "$(formatLovelace ${lovelace})")"
      fi
    else
      println "ERROR" "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
      keyDeposit=$(jq -r '.keyDeposit' "${TMP_FOLDER}"/protparams.json)
      println "DEBUG" "Funds for key deposit($(formatLovelace ${keyDeposit}) Ada) + transaction fee needed to register the wallet"
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
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> WALLET >> DE-REGISTER"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
    
    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo
    
    println "DEBUG" "# Select wallet to de-register (only registered wallets shown)"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "reg" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
      getWalletType ${wallet_name}
      case $? in
        2) println "ERROR" "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
        3) println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
      esac
    else
      if ! selectWallet "reg" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
      getWalletType ${wallet_name}
    fi
    
    getRewards ${wallet_name}
    if [[ "${reward_lovelace}" -gt 0 ]]; then
      println "\n${FG_YELLOW}WARN${NC}: wallet has unclaimed rewards, please use 'Funds >> Withdraw Rewards' before de-registration to claim your rewards"
      waitForInput && continue
    fi

    getBaseAddress ${wallet_name}
    getBalance ${base_addr}
    
    if [[ ${lovelace} -le 0 ]]; then
      println "ERROR" "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
      println "ERROR" "Funds for transaction fee needed to deregister the wallet"
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
    println "Key deposit fee that will be refunded : ${FG_CYAN}$(formatLovelace ${keyDeposit})${NC} Ada"
    
    waitForInput && continue

    ;; ###################################################################

    list)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> WALLET >> LIST"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "DEBUG" "${FG_CYAN}OFFLINE MODE${NC}: CNTools started in offline mode, wallet balance not shown!"
    fi

    while IFS= read -r -d '' wallet; do
      wallet_name=$(basename ${wallet})
      enc_files=$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c)
      if [[ ${CNTOOLS_MODE} = "CONNECTED" ]] && isWalletRegistered ${wallet_name}; then registered="yes"; else registered="no"; fi
      echo
      if [[ ${enc_files} -gt 0 && ${registered} = "yes" ]]; then
        println "${FG_GREEN}${wallet_name}${NC} - ${FG_CYAN}REGISTERED${NC} (${FG_YELLOW}encrypted${NC})"
      elif [[ ${registered} = "yes" ]]; then
        println "${FG_GREEN}${wallet_name}${NC} - ${FG_CYAN}REGISTERED${NC}"
      elif [[ ${enc_files} -gt 0 ]]; then
        println "${FG_GREEN}${wallet_name}${NC} (${FG_YELLOW}encrypted${NC})"
      else
        println "${FG_GREEN}${wallet_name}${NC}"
      fi
      getBaseAddress ${wallet_name}
      getPayAddress ${wallet_name}
      if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
        [[ -n ${base_addr} ]] && println "$(printf "%-15s : %s" "Address"  "${base_addr}")"
        [[ -n ${pay_addr} ]] && println "$(printf "%-15s : %s" "Enterprise Addr"  "${pay_addr}")"
      else
        if [[ -n ${base_addr} ]]; then
          getBalance ${base_addr}
          println "$(printf "%-19s : %s" "Address"  "${base_addr}")"
          println "$(printf "%-19s : ${FG_CYAN}%s${NC} Ada" "Funds"  "$(formatLovelace ${lovelace})")"
        fi
        if [[ -n ${pay_addr} ]]; then
          getBalance ${pay_addr}
          if [[ ${lovelace} -gt 0 ]]; then
            println "$(printf "%-19s : %s" "Enterprise Address"  "${pay_addr}")"
            println "$(printf "%-19s : ${FG_CYAN}%s${NC} Ada" "Enterprise Funds"  "$(formatLovelace ${lovelace})")"
          fi
        fi
        if [[ -z ${base_addr} && -z ${pay_addr} ]]; then
          println "${FG_RED}Not a supported wallet${NC} - genesis address?"
          println "Use an external script to send funds to a CNTools compatible wallet"
          continue
        fi
        getRewards ${wallet_name}
        if [[ "${reward_lovelace}" -ge 0 ]]; then
          println "$(printf "%-19s : ${FG_CYAN}%s${NC} Ada" "Rewards" "$(formatLovelace ${reward_lovelace})")"
          delegation_pool_id=$(jq -r '.[0].delegation // empty' <<< "${stake_address_info}")
          if [[ -n ${delegation_pool_id} ]]; then
            unset poolName
            while IFS= read -r -d '' pool; do
              getPoolID "$(basename ${pool})"
              if [[ "${pool_id_bech32}" = "${delegation_pool_id}" ]]; then
                poolName=$(basename ${pool}) && break
              fi
            done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
            println "${FG_RED}Delegated to${NC} ${FG_GREEN}${poolName}${NC} ${FG_RED}(${delegation_pool_id})${NC}"
          fi
        fi
      fi
    done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

    waitForInput && continue
    
    ;; ###################################################################

    show)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> WALLET >> SHOW"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "DEBUG" "${FG_CYAN}OFFLINE MODE${NC}: CNTools started in offline mode, limited wallet info shown!"
    fi

    tput sc
    if ! selectWallet "none" "${WALLET_PAY_VK_FILENAME}"; then
      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
    fi
    tput rc && tput ed
    
    enc_files=$(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c)

    if [[ ${enc_files} -gt 0 ]]; then
      println "Wallet: ${FG_GREEN}${wallet_name}${NC} (${FG_YELLOW}encrypted${NC})"
    else
      println "Wallet: ${FG_GREEN}${wallet_name}${NC}"
    fi

    getBaseAddress ${wallet_name}
    getPayAddress ${wallet_name}
    
    if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
      getBalance ${base_addr}
      base_lovelace=${lovelace}
      if [[ ${utx0_count} -gt 0 ]]; then
        echo
        println "${FG_CYAN}UTxOs${NC}"
        head -n 2 "${TMP_FOLDER}"/fullUtxo.out
        head -n 10 "${TMP_FOLDER}"/balance.out
        [[ ${utx0_count} -gt 10 ]] && println "... (top 10 UTx0 with most lovelace)"
      fi

      getBalance ${pay_addr}
      pay_lovelace=${lovelace}
      if [[ ${utx0_count} -gt 0 ]]; then
        echo
        println "${FG_CYAN}Enterprise UTxOs${NC}"
        head -n 2 "${TMP_FOLDER}"/fullUtxo.out
        head -n 10 "${TMP_FOLDER}"/balance.out
        [[ ${utx0_count} -gt 10 ]] && println "... (top 10 UTx0 with most lovelace)"
      fi
    fi

    echo
    if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
      if isWalletRegistered ${wallet_name}; then
        println "$(printf "%-20s : ${FG_GREEN}%s${NC}" "Registered" "YES")"
      else
        println "$(printf "%-20s : ${FG_RED}%s${NC}" "Registered" "NO")"
      fi
    else
      println "$(printf "%-20s : %s" "Registered" "Unknown")"
    fi
    println "$(printf "%-20s : %s" "Address" "${base_addr}")"
    if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
      println "$(printf "%-20s : ${FG_CYAN}%s${NC} Ada" "Funds" "$(formatLovelace ${base_lovelace})")"
      getAddressInfo "${base_addr}"
      println "$(printf "%-20s : %s" "Era" "$(jq -r '.era' <<< ${address_info})")"
      println "$(printf "%-20s : %s" "Encoding" "$(jq -r '.encoding' <<< ${address_info})")"
    fi
    println "$(printf "%-20s : %s" "Enterprise Address" "${pay_addr}")"
    if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
      println "$(printf "%-20s : ${FG_CYAN}%s${NC} Ada" "Enterprise Funds" "$(formatLovelace ${pay_lovelace})")"
      getRewards ${wallet_name}
      if [[ "${reward_lovelace}" -ge 0 ]]; then
        println "$(printf "%-20s : %s" "Reward/Stake Address" "${reward_addr}")"
        println "$(printf "%-20s : ${FG_CYAN}%s${NC} Ada" "Rewards" "$(formatLovelace ${reward_lovelace})")"
        println "$(printf "%-20s : ${FG_CYAN}%s${NC} Ada" "Funds + Rewards" "$(formatLovelace $((base_lovelace + reward_lovelace)))")"
        delegation_pool_id=$(jq -r '.[0].delegation  // empty' <<< "${stake_address_info}")
        if [[ -n ${delegation_pool_id} ]]; then
          unset poolName
          while IFS= read -r -d '' pool; do
            getPoolID "$(basename ${pool})"
            if [[ "${pool_id_bech32}" = "${delegation_pool_id}" ]]; then
              poolName=$(basename ${pool}) && break
            fi
          done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
          echo
          println "${FG_RED}Delegated to${NC} ${FG_GREEN}${poolName}${NC} ${FG_RED}(${delegation_pool_id})${NC}"
        fi
      fi
    fi

    waitForInput && continue

    ;; ###################################################################

    remove)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> WALLET >> REMOVE"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "DEBUG" "${FG_CYAN}OFFLINE MODE${NC}: CNTools started in offline mode, unable to verify wallet balance"
    fi

    echo
    println "DEBUG" "# Select wallet to remove"
    if ! selectWallet "none"; then # ${wallet_name} populated by selectWallet function
      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
    fi
    echo

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "DEBUG" "Are you sure to delete wallet ${FG_GREEN}${wallet_name}${NC}?"
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
      println "DEBUG" "${FG_RED}WARN${NC}: unable to get address for wallet and do a balance check"
      println "DEBUG" "\nAre you sure to delete wallet ${FG_GREEN}${wallet_name}${NC} anyway?"
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
      base_lovelace=${lovelace}
    else
      base_lovelace=0
    fi
    if [[ -n ${pay_addr} ]]; then
      getBalance ${pay_addr}
      pay_lovelace=${lovelace}
    else
      pay_lovelace=0
    fi
    getRewards ${wallet_name}

    if [[ ${base_lovelace} -eq 0 && ${pay_lovelace} -eq 0 && ${reward_lovelace} -le 0 ]]; then
      println "DEBUG" "INFO: This wallet appears to be empty"
      println "DEBUG" "${FG_RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup\n"
      println "DEBUG" "Are you sure to delete wallet ${FG_GREEN}${wallet_name}${NC}?"
      select_opt "[y] Yes" "[n] No"
      case $? in
        0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
           ;;
        1) echo && println "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
           ;;
      esac
    else
      println "${FG_RED}WARN${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not empty!"
      [[ ${base_lovelace} -gt 0 ]] && println "Funds : ${FG_CYAN}$(formatLovelace ${base_lovelace})${NC} Ada"
      [[ ${pay_lovelace} -gt 0 ]] && println "Enterprise Funds : ${FG_CYAN}$(formatLovelace ${base_lovelace})${NC} Ada"
      [[ ${reward_lovelace} -gt 0 ]] && println "Rewards : ${FG_CYAN}$(formatLovelace ${reward_lovelace})${NC} Ada"
      echo
      println "DEBUG" "${FG_RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup\n"
      println "DEBUG" "Are you sure to delete wallet ${FG_GREEN}${wallet_name}${NC}?"
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
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> WALLET >> DECRYPT"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    
    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue
    
    println "DEBUG" "# Select wallet to decrypt"
    if ! selectWallet "none"; then # ${wallet_name} populated by selectWallet function
      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
    fi

    filesUnlocked=0
    keysDecrypted=0

    echo
    println "DEBUG" "# Removing write protection from all wallet files"
    while IFS= read -r -d '' file; do
      if [[ ${ENABLE_CHATTR} = true && $(lsattr -R "$file") =~ -i- ]]; then
        sudo chattr -i "${file}"
      fi
      chmod 600 "${file}"
      filesUnlocked=$((++filesUnlocked))
      println "DEBUG" "${file}"
    done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    echo
    println "DEBUG" "# Decrypting GPG encrypted wallet files"
    echo
    if ! getPassword; then # $password variable populated by getPassword function
      println "\n\n" && println "ERROR" "${FG_RED}ERROR${NC}: password input aborted!"
      waitForInput && continue
    fi
    while IFS= read -r -d '' file; do
      decryptFile "${file}" "${password}" && \
      chmod 600 "${file::-4}" && \
      keysDecrypted=$((++keysDecrypted))
    done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
    unset password

    echo
    println "Wallet unprotected: ${FG_GREEN}${wallet_name}${NC}"
    println "Files unlocked:     ${filesUnlocked}"
    println "Files decrypted:    ${keysDecrypted}"
    if [[ ${filesUnlocked} -ne 0 || ${keysDecrypted} -ne 0 ]]; then
      echo
      println "DEBUG" "${FG_YELLOW}Wallet files are now unprotected${NC}"
      println "DEBUG" "Use 'WALLET >> ENCRYPT' to re-lock"
    fi

    waitForInput && continue

    ;; ###################################################################

    encrypt)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> WALLET >> ENCRYPT"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    
    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue

    println "DEBUG" "# Select wallet to encrypt"
    if ! selectWallet "none"; then # ${wallet_name} populated by selectWallet function
      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
    fi

    filesLocked=0
    keysEncrypted=0

    echo
    println "DEBUG" "# Encrypting sensitive wallet keys with GPG"
    echo
    if ! getPassword confirm; then # $password variable populated by getPassword function
      println "\n\n" && println "ERROR" "${FG_RED}ERROR${NC}: password input aborted!"
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

    echo
    println "DEBUG" "# Write protecting all wallet keys with 400 permission and if enabled 'chattr +i'"
    while IFS= read -r -d '' file; do
      [[ ${file} = *.addr ]] && continue
      chmod 400 "${file}"
      if [[ ${ENABLE_CHATTR} = true && ! $(lsattr -R "$file") =~ -i- ]]; then
        sudo chattr +i "${file}"
      fi
      filesLocked=$((++filesLocked))
      println "DEBUG" "${file}"
    done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    echo
    println "Wallet protected: ${FG_GREEN}${wallet_name}${NC}"
    println "Files locked:     ${filesLocked}"
    println "Files encrypted:  ${keysEncrypted}"
    if [[ ${filesLocked} -ne 0 || ${keysEncrypted} -ne 0 ]]; then
      echo
      println "DEBUG" "${FG_BLUE}INFO${NC}: wallet files are now protected"
      println "DEBUG" "Use 'WALLET >> DECRYPT' to unlock"
    fi

    waitForInput && continue

    ;; ###################################################################

  esac

  ;; ###################################################################

  funds)

  clear
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println " >> FUNDS"
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println "OFF" " Handle Funds\n\n"\
" ) Send     - send Ada from a local wallet to an address or a wallet\n"\
" ) Delegate - delegate stake wallet to a pool\n"\
" ) Withdraw - withdraw earned rewards to base address\n"\
"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

  println "DEBUG" " Select funds operation\n"
  select_opt "[s] Send" "[d] Delegate" "[w] Withdraw Rewards" "[h] Home"
  case $? in
    0) SUBCOMMAND="send" ;;
    1) SUBCOMMAND="delegate" ;;
    2) SUBCOMMAND="withdrawrewards" ;;
    3) continue ;;
  esac

  case $SUBCOMMAND in
    send)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> FUNDS >> SEND"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo

    println "DEBUG" "# Select ${FG_CYAN}source${NC} wallet"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "balance" "${WALLET_PAY_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
      getWalletType ${wallet_name}
      case $? in
        2) println "ERROR" "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
        3) println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
      esac
    else
      if ! selectWallet "balance" "${WALLET_PAY_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
      getWalletType ${wallet_name}
    fi
    s_wallet="${wallet_name}"
    s_payment_vk_file="${payment_vk_file}"
    s_payment_sk_file="${payment_sk_file}"
    echo

    getBaseAddress ${s_wallet}
    getPayAddress ${s_wallet}
    getBalance ${base_addr}
    base_lovelace=${lovelace}
    getBalance ${pay_addr}
    pay_lovelace=${lovelace}

    if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
      # Both payment and base address available with funds, let user choose what to use
      println "DEBUG" "Select source wallet address"
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        println "DEBUG" "$(printf "%s\t\t${FG_CYAN}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
        println "DEBUG" "$(printf "%s\t${FG_CYAN}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
      fi
      echo
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
        println "DEBUG" "$(printf "%s\t${FG_CYAN}%s${NC} Ada\n" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
      fi
    elif [[ ${base_lovelace} -gt 0 ]]; then
      s_addr="${base_addr}"
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        println "DEBUG" "$(printf "%s\t\t${FG_CYAN}%s${NC} Ada\n" "Funds :"  "$(formatLovelace ${base_lovelace})")"
      fi
    else
      println "ERROR" "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${s_wallet}${NC}"
      waitForInput && continue
    fi

    # Amount
    println "DEBUG" "# Amount to Send (in Ada)"
    echo
    println "DEBUG" "Valid entry:  ${FG_CYAN}Integer${NC} (e.g. 15) or ${FG_CYAN}Decimal${NC} (e.g. 956.1235) - commas allowed as thousand separator"
    println "DEBUG" "              The string '${FG_CYAN}all${NC}' to send all available funds in source wallet"
    echo
    println "DEBUG" "Info:         If destination and source wallet is the same and amount set to 'all',"
    println "DEBUG" "              wallet will be defraged, ie converts multiple UTxO's to one"
    echo
    
    sleep 0.1 && read -r -p "Amount (Ada): " amountADA 2>&6 && println "LOG" "Amount (Ada): ${amountADA}"
    amountADA="${amountADA//,}"

    echo
    if  [[ "${amountADA}" != "all" ]]; then
      if ! AdaToLovelace "${amountADA}" >/dev/null; then
        waitForInput && continue
      fi
      amount_lovelace=$(AdaToLovelace "${amountADA}")
      println "DEBUG" "Fee payed by sender? [else amount sent is reduced]"
      select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
      case $? in
        0) include_fee="no" ;;
        1) include_fee="yes" ;;
        2) continue ;;
      esac
    else
      getBalance ${s_addr}
      amount_lovelace=${lovelace}
      println "DEBUG" "Ada to send set to total supply: $(formatLovelace ${amount_lovelace})"
      include_fee="yes"
    fi
    echo

    # Destination
    d_wallet=""
    println "DEBUG" "# Select ${FG_CYAN}destination${NC} type"
    select_opt "[w] Wallet" "[a] Address" "[Esc] Cancel"
    case $? in
      0) if ! selectWallet "balance"; then # ${wallet_name} populated by selectWallet function
           [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
         fi
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
           println "ERROR" "\n${FG_RED}ERROR${NC}: sending to same address as source not supported"
           waitForInput && continue
         else
           println "ERROR" "\n${FG_RED}ERROR${NC}: no address found for wallet ${FG_GREEN}${d_wallet}${NC} :("
           waitForInput && continue
         fi
         ;;
      1) echo && sleep 0.1 && read -r -p "Address: " d_addr 2>&6 && println "LOG" "Address: ${d_addr}" ;;
      2) continue ;;
    esac
    # Destination could be empty, if so without getting a valid address
    if [[ -z ${d_addr} ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: destination address field empty"
      waitForInput && continue
    fi

    if ! sendAda; then
      waitForInput && continue
    fi

    echo
    if ! verifyTx ${s_addr}; then waitForInput && continue; fi

    s_balance=${lovelace}
    getBalance ${d_addr}
    d_balance=${lovelace}

    getPayAddress ${s_wallet}
    [[ "${pay_addr}" = "${s_addr}" ]] && s_wallet_type=" (Enterprise)" || s_wallet_type=""
    getPayAddress ${d_wallet}
    [[ "${pay_addr}" = "${d_addr}" ]] && d_wallet_type=" (Enterprise)" || d_wallet_type=""

    echo
    println "Transaction"
    println "  From          : ${FG_GREEN}${s_wallet}${NC}${s_wallet_type}"
    println "  Amount        : $(formatLovelace ${amount_lovelace}) Ada"
    if [[ -n "${d_wallet}" ]]; then
      println "  To            : ${FG_GREEN}${d_wallet}${NC}${d_wallet_type}"
    else
      println "  To            : ${d_addr}"
    fi
    println "  Fees          : $(formatLovelace ${min_fee}) Ada"
    println "  Balance"
    println "  - Source      : $(formatLovelace ${s_balance}) Ada"
    println "  - Destination : $(formatLovelace ${d_balance}) Ada"

    waitForInput && continue

    ;; ###################################################################

    delegate)  # [WALLET NAME] [POOL NAME]

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> FUNDS >> DELEGATE"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo

    println "DEBUG" "# Select wallet to delegate"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "delegate" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
      getWalletType ${wallet_name}
      case $? in
        2) println "ERROR" "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
        3) println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
      esac
    else
      if ! selectWallet "delegate" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
      getWalletType ${wallet_name}
    fi

    getBaseAddress ${wallet_name}
    getBalance ${base_addr}
    if [[ ${lovelace} -gt 0 ]]; then
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        println "DEBUG" "$(printf "%s\t${FG_CYAN}%s${NC} Ada" "Funds in wallet:"  "$(formatLovelace ${lovelace})")"
      fi
    else
      println "ERROR" "\n${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
      waitForInput && continue
    fi
    getRewards ${wallet_name}

    if [[ reward_lovelace -eq -1 ]]; then
      if [[ ${op_mode} = "online" ]]; then
        if ! registerStakeWallet ${wallet_name}; then waitForInput && continue; fi
      else
        println "ERROR" "\n${FG_YELLOW}The wallet is not a registered wallet on chain and CNTools run in hybrid mode${NC}"
        println "ERROR" "Please first register the wallet using 'Wallet >> Register'"
        waitForInput && continue
      fi
    fi

    echo
    println "DEBUG" "Do you want to delegate to a local pool or specify the pools cold vkey cbor-hex?"
    select_opt "[p] Pool" "[v] Vkey" "[Esc] Cancel"
    case $? in
      0) if ! selectPool "reg" "${POOL_COLDKEY_VK_FILENAME}"; then # ${pool_name} populated by selectPool function
           waitForInput && continue
         fi
         pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
         ;;
      1) sleep 0.1 && read -r -p "vkey cbor-hex(blank to cancel): " vkey_cbor 2>&6 && println "LOG" "vkey cbor-hex(blank to cancel): ${vkey_cbor}"
         [[ -z "${vkey_cbor}" ]] && continue
         pool_name="${vkey_cbor}"
         pool_coldkey_vk_file="${TMP_FOLDER}"/pool_delegation.vkey
         printf "{\"type\":\"StakePoolVerificationKey_ed25519\",\"description\":\"Stake Pool Operator Verification Key\",\"cborHex\":\"%s\"}" ${vkey_cbor} > "${pool_coldkey_vk_file}"
         ;;
      2) continue ;;
    esac

    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
    pool_delegcert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DELEGCERT_FILENAME}"

    println "ACTION" "${CCLI} stake-address delegation-certificate --stake-verification-key-file ${stake_vk_file} --cold-verification-key-file ${pool_coldkey_vk_file} --out-file ${pool_delegcert_file}"
    ${CCLI} stake-address delegation-certificate --stake-verification-key-file "${stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${pool_delegcert_file}"

    if ! delegate; then
      if [[ ${op_mode} = "online" ]]; then
        echo && println "ERROR" "${FG_RED}ERROR${NC}: failure during delegation, removing newly created delegation certificate file"
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
    println "Amount : $(formatLovelace ${lovelace}) Ada"

    waitForInput && continue

    ;; ###################################################################

    withdrawrewards)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> FUNDS >> WITHDRAW REWARDS"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo

    println "DEBUG" "# Select wallet to withdraw funds from"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "reward" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
      getWalletType ${wallet_name}
      case $? in
        2) println "ERROR" "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
        3) println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
      esac
    else
      if ! selectWallet "reward" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
      getWalletType ${wallet_name}
    fi
    echo

    getBaseAddress ${wallet_name}
    getBalance ${base_addr}
    getRewards ${wallet_name}

    if [[ ${reward_lovelace} -le 0 ]]; then
      println "ERROR" "Failed to locate any rewards associated with the chosen wallet, please try another one"
      waitForInput && continue
    elif [[ ${lovelace} -eq 0 ]]; then
      println "ERROR" "${FG_YELLOW}WARN${NC}: No funds in base address, please send funds to base address of wallet to cover withdraw transaction fee"
      waitForInput && continue
    fi

    println "DEBUG" "$(printf "%s\t${FG_CYAN}%s${NC} Ada" "Funds"  "$(formatLovelace ${lovelace})")"
    println "DEBUG" "$(printf "%s\t${FG_CYAN}%s${NC} Ada" "Rewards"  "$(formatLovelace ${reward_lovelace})")"

    if ! withdrawRewards; then
      waitForInput && continue
    fi

    echo
    if ! verifyTx ${base_addr}; then waitForInput && continue; fi

    getRewards ${wallet_name}

    echo
    println "Rewards successfully withdrawn"
    println "$(printf "%s\t${FG_CYAN}%s${NC} Ada" "Funds"  "$(formatLovelace ${lovelace})")"
    println "$(printf "%s\t${FG_CYAN}%s${NC} Ada" "Rewards"  "$(formatLovelace ${reward_lovelace})")"

    waitForInput && continue

    ;; ###################################################################

  esac

  ;; ###################################################################

  pool)

  clear
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println " >> POOL"
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println "OFF" " Pool Management\n\n"\
" ) New      - create a new pool\n"\
" ) Register - register created pool on chain using a stake wallet (pledge wallet)\n"\
" ) Modify   - change pool parameters and register updated pool values on chain\n"\
" ) Retire   - de-register stake pool from chain in specified epoch\n"\
" ) List     - a compact list view of available local pools\n"\
" ) Show     - detailed view of specified pool\n"\
" ) Rotate   - rotate pool KES keys\n"\
" ) Decrypt  - remove write protection and decrypt pool\n"\
" ) Encrypt  - encrypt pool cold keys and make all files immutable\n"\
"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println "DEBUG" " Select Pool operation\n"
  select_opt "[n] New" "[r] Register" "[m] Modify" "[x] Retire" "[l] List" "[s] Show" "[o] Rotate" "[d] Decrypt" "[e] Encrypt" "[h] Home"
  case $? in
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
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> POOL >> NEW"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    sleep 0.1 && read -r -p "Pool Name: " pool_name 2>&6 && println "LOG" "Pool Name: ${pool_name}"
    # Remove unwanted characters from pool name
    pool_name=${pool_name//[^[:alnum:]]/_}
    if [[ -z "${pool_name}" ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: Empty pool name, please retry!"
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
      println "ERROR" "${FG_RED}WARN${NC}: A pool ${FG_GREEN}$pool_name${NC} already exists"
      println "ERROR" "      Choose another name or delete the existing one"
      waitForInput && continue
    fi

    println "ACTION" "${CCLI} node key-gen-KES --verification-key-file \"${pool_hotkey_vk_file}\" --signing-key-file \"${pool_hotkey_sk_file}\""
    ${CCLI} node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}"
    if [ -f "${POOL_FOLDER}-pregen/${pool_name}/${POOL_ID_FILENAME}" ]; then
      mv ${POOL_FOLDER}'-pregen/'${pool_name}/* ${POOL_FOLDER}/${pool_name}/
      rm -r ${POOL_FOLDER}'-pregen/'${pool_name}
    else
      println "ACTION" "${CCLI} node key-gen --cold-verification-key-file \"${pool_coldkey_vk_file}\" --cold-signing-key-file \"${pool_coldkey_sk_file}\" --operational-certificate-issue-counter-file \"${pool_opcert_counter_file}\""
      ${CCLI} node key-gen --cold-verification-key-file "${pool_coldkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}"
    fi
    println "ACTION" "${CCLI} node key-gen-VRF --verification-key-file \"${pool_vrf_vk_file}\" --signing-key-file \"${pool_vrf_sk_file}\""
    ${CCLI} node key-gen-VRF --verification-key-file "${pool_vrf_vk_file}" --signing-key-file "${pool_vrf_sk_file}"
    chmod 700 ${POOL_FOLDER}/${pool_name}/*
    getPoolID ${pool_name}

    echo
    println "Pool: ${FG_GREEN}${pool_name}${NC}"
    [[ -n ${pool_id} ]] && println "ID (hex)    : ${pool_id}"
    [[ -n ${pool_id_bech32} ]] && println "ID (bech32) : ${pool_id_bech32}"

    waitForInput && continue

    ;; ###################################################################

    register|modify)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> POOL >> ${SUBCOMMAND^^}"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue
    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitForInput && continue

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo

    println "DEBUG" "# Select pool"
    [[ ${SUBCOMMAND} = "register" ]] && pool_filter="non-reg" || pool_filter="reg"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_COLDKEY_SK_FILENAME}" "${POOL_VRF_VK_FILENAME}"; then # ${pool_name} populated by selectPool function
        waitForInput && continue
      fi
    else
      if ! selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_VRF_VK_FILENAME}"; then # ${pool_name} populated by selectPool function
        waitForInput && continue
      fi
    fi
    echo

    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
    
    println "DEBUG" "# Pool Parameters"
    
    if [[ ${SUBCOMMAND} = "modify" ]]; then
      if [[ ! -f ${pool_config} ]]; then
        println "${FG_YELLOW}WARN${NC}: Missing pool config file: ${pool_config}"
        println "Unable to show old values, please re-enter all values to generate a new pool config file"
      else
        println "DEBUG" "Old registration values shown as default, press enter to use default value"
      fi
    else
      println "DEBUG" "press enter to use default value"
    fi
    echo

    pledge_ada=50000 # default pledge
    [[ -f "${pool_config}" ]] && pledge_ada=$(jq -r '.pledgeADA //0' "${pool_config}")
    sleep 0.1 && read -r -p "Pledge (in Ada, default: $(formatAda ${pledge_ada})): " pledge_enter 2>&6 && println "LOG" "Pledge (in Ada, default: $(formatAda ${pledge_ada})): ${pledge_enter}"
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
    sleep 0.1 && read -r -p "Margin (in %, default: ${margin}): " margin_enter 2>&6 && println "LOG" "Margin (in %, default: ${margin}): ${margin_enter}"
    if [[ -n "${margin_enter}" ]]; then
      if ! pctToFraction "${margin_enter}" >/dev/null; then
        waitForInput && continue
      fi
      margin_fraction=$(pctToFraction "${margin_enter}")
      margin="${margin_enter}"
    else
      margin_fraction=$(pctToFraction "${margin}")
    fi

    minPoolCost=$(( $(jq -r '.minPoolCost //0' "${TMP_FOLDER}"/protparams.json) / 1000000 )) # convert to Ada
    [[ -f ${pool_config} ]] && cost_ada=$(jq -r '.costADA //0' "${pool_config}") || cost_ada=${minPoolCost} # default cost
    [[ ${cost_ada} -lt ${minPoolCost} ]] && cost_ada=${minPoolCost} # raise old value to new minimum cost
    sleep 0.1 && read -r -p "Cost (in Ada, minimum: ${minPoolCost}, default: $(formatAda ${cost_ada})): " cost_enter 2>&6 && println "LOG" "Cost (in Ada, minimum: ${minPoolCost}, default: $(formatAda ${cost_ada})): ${cost_enter}"
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
    if [[ ${cost_ada} -lt ${minPoolCost} ]]; then
      println "ERROR" "\n${FG_RED}ERROR${NC}: cost set lower than allowed"
      waitForInput && continue
    fi

    println "DEBUG" "\n# Pool Metadata\n"
    
    pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta.json"
    if [[ ! -f "${pool_config}" ]] || ! meta_json_url=$(jq -er .json_url "${pool_config}"); then meta_json_url="https://foo.bat/poolmeta.json"; fi

    sleep 0.1 && read -r -p "Enter Pool's JSON URL to host metadata file - URL length should be less than 64 chars (default: ${meta_json_url}): " json_url_enter 2>&6 && println "LOG" "Enter Pool's JSON URL to host metadata file - URL length should be less than 64 chars (default: ${meta_json_url}): ${json_url_enter}"
    [[ -n "${json_url_enter}" ]] && meta_json_url="${json_url_enter}"
    if [[ ! "${meta_json_url}" =~ https?://.* || ${#meta_json_url} -gt 64 ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
      waitForInput && continue
    fi

    metadata_done=false
    meta_tmp="${TMP_FOLDER}/url_poolmeta.json"
    if curl -sL -m ${CURL_TIMEOUT} -o "${meta_tmp}" ${meta_json_url} && jq -er . "${meta_tmp}" &>/dev/null; then
      [[ $(wc -c <"${meta_tmp}") -gt 512 ]] && println "ERROR" "${FG_RED}ERROR${NC}: file at specified URL contain more than allowed 512b of data!" && waitForInput && continue
      echo && jq -r . "${meta_tmp}" >&3 && echo
      if ! jq -er .name "${meta_tmp}" &>/dev/null; then println "ERROR" "${FG_RED}ERROR${NC}: unable to get 'name' field from downloaded metadata file!" && waitForInput && continue; fi
      if ! jq -er .ticker "${meta_tmp}" &>/dev/null; then println "ERROR" "${FG_RED}ERROR${NC}: unable to get 'ticker' field from downloaded metadata file!" && waitForInput && continue; fi
      if ! jq -er .homepage "${meta_tmp}" &>/dev/null; then println "ERROR" "${FG_RED}ERROR${NC}: unable to get 'homepage' field from downloaded metadata file!" && waitForInput && continue; fi
      if ! jq -er .description "${meta_tmp}" &>/dev/null; then println "ERROR" "${FG_RED}ERROR${NC}: unable to get 'description' field from downloaded metadata file!" && waitForInput && continue; fi
      println "DEBUG" "Metadata exists at URL.  Use existing data?"
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

      sleep 0.1 && read -r -p "Enter Pool's Name (default: ${meta_name}): " name_enter 2>&6 && println "LOG" "Enter Pool's Name (default: ${meta_name}): ${name_enter}"
      [[ -n "${name_enter}" ]] && meta_name="${name_enter}"
      if [[ ${#meta_name} -gt 50 ]]; then
        println "ERROR" "${FG_RED}ERROR${NC}: Name cannot exceed 50 characters"
        waitForInput && continue
      fi
      sleep 0.1 && read -r -p "Enter Pool's Ticker , should be between 3-5 characters (default: ${meta_ticker}): " ticker_enter 2>&6 && println "LOG" "Enter Pool's Ticker , should be between 3-5 characters (default: ${meta_ticker}): ${ticker_enter}"
      ticker_enter=${ticker_enter//[^[:alnum:]]/}
      [[ -n "${ticker_enter}" ]] && meta_ticker="${ticker_enter^^}"
      if [[ ${#meta_ticker} -lt 3 || ${#meta_ticker} -gt 5 ]]; then
        println "ERROR" "${FG_RED}ERROR${NC}: ticker must be between 3-5 characters"
        waitForInput && continue
      fi
      sleep 0.1 && read -r -p "Enter Pool's Description (default: ${meta_description}): " desc_enter 2>&6 && println "LOG" "Enter Pool's Description (default: ${meta_description}): ${desc_enter}"
      [[ -n "${desc_enter}" ]] && meta_description="${desc_enter}"
      if [[ ${#meta_description} -gt 255 ]]; then
        println "ERROR" "${FG_RED}ERROR${NC}: Description cannot exceed 255 characters"
        waitForInput && continue
      fi
      sleep 0.1 && read -r -p "Enter Pool's Homepage (default: ${meta_homepage}): " homepage_enter 2>&6 && println "LOG" "Enter Pool's Homepage (default: ${meta_homepage}): ${homepage_enter}"
      [[ -n "${homepage_enter}" ]] && meta_homepage="${homepage_enter}"
      if [[ ! "${meta_homepage}" =~ https?://.* || ${#meta_homepage} -gt 64 ]]; then
        println "ERROR" "${FG_RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
        waitForInput && continue
      fi
      println "DEBUG" "\nOptionally set an extended metadata URL?"
      select_opt "[n] No" "[y] Yes"
      case $? in
        0) meta_extended_option=""
           ;;
        1) echo && sleep 0.1 && read -r -p "Enter URL to extended metadata (default: ${meta_extended}): " extended_enter 2>&6 && println "LOG" "Enter URL to extended metadata (default: ${meta_extended}): ${extended_enter}"
           extended_enter="${extended_enter}"
           [[ -n "${extended_enter}" ]] && meta_extended="${extended_enter}"
           if [[ ! "${meta_extended}" =~ https?://.* || ${#meta_extended} -gt 64 ]]; then
             println "ERROR" "${FG_RED}ERROR${NC}: invalid extended URL format or more than 64 chars in length"
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
        println "ERROR" "\n${FG_RED}ERROR${NC}: Total metadata size cannot exceed 512 chars in length, current length: ${metadata_size}"
        waitForInput && continue
      else
        cp -f "${new_pool_meta_file}" "${pool_meta_file}"
      fi

      println "DEBUG" "\n${FG_YELLOW}Please host file ${pool_meta_file} as-is at ${meta_json_url}${NC}"
      waitForInput "Press any key to proceed with registration after metadata file is uploaded"
    fi

    relay_output=""
    relay_array=()
    println "DEBUG" "\n# Pool Relay Registration"
    # ToDo SRV & IPv6 support
    if [[ -f "${pool_config}" && $(jq '.relays | length' "${pool_config}") -gt 0 ]]; then
      println "DEBUG" "\nPrevious relay configuration:\n"
      jq -r '["TYPE","ADDRESS","PORT"], (.relays[] | [.type //"-",.address //"-",.port //"-"]) | @tsv' "${pool_config}" | column -t >&3
      println "DEBUG" "\nReuse previous relay configuration?"
      select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
      case $? in
        0) while read -r type address port; do
             relay_array+=( "type" "${type}" "address" "${address}" "port" "${port}" )
             if [[ ${type} = "DNS_A" ]]; then
               relay_output+="--single-host-pool-relay ${address} --pool-relay-port ${port} "
             elif [[ ${type} = "IPv4" ]]; then
               relay_output+="--pool-relay-port ${port} --pool-relay-ipv4 ${address} "
             fi
           done< <(jq -r '.relays[] | "\(.type) \(.address) \(.port)"' "${pool_config}")
           ;;
        1) : ;; # Do nothing
        2) continue ;;
      esac
    fi
    if [[ -z ${relay_output} ]]; then
      while true; do
        select_opt "[d] A or AAAA DNS record (single)" "[4] IPv4 address (multiple)" "[Esc] Cancel"
        case $? in
          0) sleep 0.1 && read -r -p "Enter relays's DNS record, only A or AAAA DNS records: " relay_dns_enter 2>&6 && println "LOG" "Enter relays's DNS record, only A or AAAA DNS records: ${relay_dns_enter}"
             if [[ -z "${relay_dns_enter}" ]]; then
               println "ERROR" "${FG_RED}ERROR${NC}: DNS record can not be empty!"
             else
               sleep 0.1 && read -r -p "Enter relays's port: " relay_port_enter 2>&6 && println "LOG" "Enter relays's port: ${relay_port_enter}"
               if [[ -n "${relay_port_enter}" ]]; then
                 if [[ ! "${relay_port_enter}" =~ ^[0-9]+$ || "${relay_port_enter}" -lt 1 || "${relay_port_enter}" -gt 65535 ]]; then
                   println "ERROR" "${FG_RED}ERROR${NC}: invalid port number!"
                 else
                   relay_array+=( "type" "DNS_A" "address" "${relay_dns_enter}" "port" "${relay_port_enter}" )
                   relay_output+="--single-host-pool-relay ${relay_dns_enter} --pool-relay-port ${relay_port_enter} "
                 fi
               else
                 println "ERROR" "${FG_RED}ERROR${NC}: Port can not be empty!"
               fi
             fi
             ;;
          1) sleep 0.1 && read -r -p "Enter relays's IPv4 address: " relay_ipv4_enter 2>&6 && println "LOG" "Enter relays's IPv4 address: ${relay_ipv4_enter}"
             if [[ -n "${relay_ipv4_enter}" ]]; then
               if ! validIP "${relay_ipv4_enter}"; then
                 println "ERROR" "${FG_RED}ERROR${NC}: invalid IPv4 address format!"
               else
                 sleep 0.1 && read -r -p "Enter relays's port: " relay_port_enter 2>&6 && println "LOG" "Enter relays's port: ${relay_port_enter}"
                 if [[ -n "${relay_port_enter}" ]]; then
                   if [[ ! "${relay_port_enter}" =~ ^[0-9]+$ || "${relay_port_enter}" -lt 1 || "${relay_port_enter}" -gt 65535 ]]; then
                     println "ERROR" "${FG_RED}ERROR${NC}: invalid port number!"
                   else
                     relay_array+=( "type" "IPv4" "address" "${relay_ipv4_enter}" "port" "${relay_port_enter}" )
                     relay_output+="--pool-relay-port ${relay_port_enter} --pool-relay-ipv4 ${relay_ipv4_enter} "
                   fi
                 else
                   println "ERROR" "${FG_RED}ERROR${NC}: Port can not be empty!"
                 fi
               fi
             else
               println "ERROR" "${FG_RED}ERROR${NC}: IPv4 address can not be empty!"
             fi
             ;;
          2) continue 2 ;;
        esac
        println "DEBUG" "Add more relay entries?"
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
      println "DEBUG" "# Previous Owner(s)/Reward wallets"
      if jq -er '.pledgeWallet' "${pool_config}" &>/dev/null; then # legacy support
        owner_wallets+=( "$(jq -r '.pledgeWallet' "${pool_config}")" )
        println "DEBUG" "Owner wallet #1 : ${FG_GREEN}${owner_wallets[0]}${NC}"
      else
        for owner in $(jq -c '.owners[]' "${pool_config}"); do
          wallet_name=$(jq -r '.wallet_name' <<< "${owner}")
          owner_wallets+=( "${wallet_name}" )
          println "DEBUG" "Owner wallet #$(jq -r '.id' <<< "${owner}") : ${FG_GREEN}${wallet_name}${NC}"
        done
      fi
      reward_wallet=$(jq -r '.rewardWallet //empty' "${pool_config}")
      println "DEBUG" "Reward wallet   : ${FG_GREEN}${reward_wallet}${NC}"
      println "DEBUG" "\nReuse previous Owner(s)/Reward wallets?"
      select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
      case $? in
        0) reuse_wallets='Y'
           for wallet_name in "${owner_wallets[@]}"; do # Validate each wallet that they still exist and contain the correct keys
             getWalletType ${wallet_name}
             case $? in
               0) if [[ ${wallet_name} = "${owner_wallets[0]}" ]]; then # main owner, must be a CLI wallet
                    println "ERROR" "${FG_RED}ERROR${NC}: main/first pool owner can NOT be a hardware wallet!"
                    println "ERROR" "Use a CLI wallet as owner with enough funds to pay for pool deposit and registration transaction fee"
                    println "ERROR" "Add the hardware wallet as an additional multi-owner to the pool later in the pool registration wizard"
                    waitForInput "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N' && break
                  else hw_owner_wallets='Y'; fi ;;
               2) if [[ ${op_mode} = "online" ]]; then
                    println "ERROR" "${FG_RED}ERROR${NC}: signing keys encrypted for wallet ${FG_GREEN}${wallet_name}${NC}, please decrypt before use!"
                    waitForInput && continue 2
                  fi ;;
               3) println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                  waitForInput "Did you mean to run in Hybrid mode?  press any key to return home!" && continue 2 ;;
               4) println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake verification keys missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                  waitForInput "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N' && break ;;
             esac
             if [[ ${wallet_name} = "${owner_wallets[0]}" ]] && ! isWalletRegistered ${wallet_name}; then # make sure at least main owner is registered
               if [[ ${op_mode} = "hybrid" ]]; then
                 println "ERROR" "\n${FG_RED}ERROR${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not a registered wallet on chain and CNTools run in hybrid mode"
                 println "ERROR" "Please first register main owner wallet to use in pool registration using 'Wallet >> Register'"
                 waitForInput && continue 2
               fi
               getBaseAddress ${wallet_name}
               getBalance ${base_addr}
               if [[ ${lovelace} -eq 0 ]]; then
                 println "ERROR" "${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}, needed to pay for registration fee"
                 waitForInput && continue 2
               fi
               if ! registerStakeWallet ${wallet_name}; then waitForInput && continue 2; fi
             fi
           done
           getWalletType ${reward_wallet}
           case $? in
             0) hw_reward_is_mu='N'
                for wallet_name in "${owner_wallets[@]}"; do # HW reward wallet, make sure its also a multi-owner to the pool
                  [[ "${wallet_name}" = "${reward_wallet}" ]] && hw_reward_is_mu='Y' && break
                done
                if [[ ${hw_reward_is_mu} = 'N' ]]; then # main owner, must be a CLI wallet
                  println "ERROR" "${FG_RED}ERROR${NC}: reward wallet detected as hardware wallet but NOT a multi-owner to the pool!"
                  println "ERROR" "If hardware wallet is to be used for rewards, it MUST also be a multi-owner to the pool"
                  waitForInput "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N'
                else hw_reward_wallet='Y'; fi ;;
             2) if [[ ${op_mode} = "online" && ${SUBCOMMAND} = "register" && ${hw_owner_wallets} = 'N' ]]; then
                  println "ERROR" "${FG_RED}ERROR${NC}: signing keys encrypted for reward wallet ${FG_GREEN}${reward_wallet}${NC}, please decrypt before use!"
                  waitForInput && continue
                fi ;;
             3) if [[ ${SUBCOMMAND} = "register" && ${hw_owner_wallets} = 'N' ]]; then
                  println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from reward wallet ${FG_GREEN}${reward_wallet}${NC}!"
                  waitForInput "Did you mean to run in Hybrid mode?  press any key to return home!" && continue
                fi ;;
             4) println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake verification keys missing from reward wallet ${FG_GREEN}${reward_wallet}${NC}!"
                waitForInput "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N' ;;
           esac
           if ! isWalletRegistered ${reward_wallet}; then
             if [[ ${op_mode} = "hybrid" ]]; then
               println "ERROR" "\n${FG_RED}ERROR${NC}: reward wallet ${FG_GREEN}${reward_wallet}${NC} not a registered wallet on chain and CNTools run in hybrid mode"
               println "ERROR" "Please first register the rewards wallet to use in pool registration using 'Wallet >> Register'"
               waitForInput && continue
             fi
             getBaseAddress ${reward_wallet}
             getBalance ${base_addr}
             if [[ ${lovelace} -eq 0 ]]; then
               println "ERROR" "${FG_RED}ERROR${NC}: no funds available in base address for reward wallet ${FG_GREEN}${reward_wallet}${NC}, needed to pay for registration fee"
               waitForInput && continue
             fi
             if ! registerStakeWallet ${reward_wallet}; then waitForInput && continue; fi
           fi
           ;;
        1) owner_wallets=() && reward_wallet="" && reuse_wallets='N'
           println "DEBUG" "\n${FG_YELLOW}If new wallets are chosen for owner(s)/reward, a manual delegation to the pool for each wallet is needed if not done already!${NC}"
           ;;
        2) continue ;;
      esac
    fi

    if [[ ${reuse_wallets} = 'N' ]]; then
      println "DEBUG" "# Select main ${FG_CYAN}owner/pledge${NC} wallet (normal CLI wallet)"
      if [[ ${op_mode} = "online" ]]; then
        if ! selectWallet "delegate" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
          [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
        fi
        getWalletType ${wallet_name}
        case $? in
          0) println "ERROR" "${FG_RED}ERROR${NC}: main pool owner can NOT be a hardware wallet!"
             println "ERROR" "Use a CLI wallet as owner with enough funds to pay for pool deposit and registration transaction fee"
             println "ERROR" "Add the hardware wallet as an additional multi-owner to the pool later in the pool registration wizard"
             waitForInput && continue ;;
          2) println "ERROR" "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
          3) println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
        esac
      else
        if ! selectWallet "delegate" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
          [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
        fi
        getWalletType ${wallet_name}
      fi
      if ! isWalletRegistered ${wallet_name}; then
        if [[ ${op_mode} = "hybrid" ]]; then
          println "ERROR" "\n${FG_RED}ERROR${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not a registered wallet on chain and CNTools run in hybrid mode"
          println "ERROR" "Please first register all wallets to use in pool registration using 'Wallet >> Register'"
          waitForInput && continue
        fi
        getBaseAddress ${wallet_name}
        getBalance ${base_addr}
        if [[ ${lovelace} -eq 0 ]]; then
          println "ERROR" "${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}, needed to pay for registration fee"
          waitForInput && continue
        fi
        if ! registerStakeWallet ${wallet_name}; then waitForInput && continue; fi
      fi
      owner_wallets+=( "${wallet_name}" )
      println "DEBUG" "Owner #1 : ${FG_GREEN}${wallet_name}${NC} added!"
    fi
    
    if [[ ${reuse_wallets} = 'N' ]]; then
      println "DEBUG" "Register a multi-owner pool?"
      while true; do
        select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
        case $? in
          0) break ;;
          1) if selectWallet "delegate" "${WALLET_STAKE_VK_FILENAME}" "${owner_wallets[@]}"; then # ${wallet_name} populated by selectWallet function
               getWalletType ${wallet_name}
               case $? in
                 0) hw_owner_wallets='Y' ;;
                 2) if [[ ${op_mode} = "online" ]]; then
                      println "ERROR" "${FG_RED}ERROR${NC}: signing keys encrypted for wallet ${FG_GREEN}${wallet_name}${NC}, please decrypt before use!"
                      waitForInput && continue 2
                    fi ;;
                 3) println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                    waitForInput "Did you mean to run in Hybrid mode?  press any key to return home!" && continue 2 ;;
                 4) println "ERROR" "${FG_RED}ERROR${NC}: stake verification key missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                    println "DEBUG" "Add another owner?" && continue ;;
               esac
             else
               println "DEBUG" "Add more owners?" && continue
             fi
             owner_wallets+=( "${wallet_name}" )
             println "DEBUG" "Owner #${#owner_wallets[@]} : ${FG_GREEN}${wallet_name}${NC} added!"
             ;;
          2) continue 2 ;;
        esac
        println "DEBUG" "Add more owners?"
      done
    fi

    if [[ ${reuse_wallets} = 'N' ]]; then
      println "DEBUG" "Use a separate rewards wallet from main owner?"
      select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
      case $? in
        0) reward_wallet="${owner_wallets[0]}" ;;
        1) if ! selectWallet "none" "${WALLET_STAKE_VK_FILENAME}" "${owner_wallets[0]}"; then # ${wallet_name} populated by selectWallet function
             [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
           fi
           reward_wallet="${wallet_name}"
           if ! isWalletRegistered ${reward_wallet}; then
             if [[ ${op_mode} = "hybrid" ]]; then
               println "ERROR" "\nReward wallet ${FG_GREEN}${reward_wallet}${NC} not a registered wallet on chain and CNTools run in hybrid mode"
               println "ERROR" "Please first register all wallets to use in pool registration using 'Wallet >> Register'"
               waitForInput && continue
             fi
             getWalletType ${reward_wallet}
             case $? in
               0) hw_reward_wallet='Y' ;;
               2) println "ERROR" "${FG_RED}ERROR${NC}: stake signing key encrypted, please decrypt before use!" && waitForInput && continue ;;
               3) println "ERROR" "${FG_RED}ERROR${NC}: stake signing key missing from wallet!" && waitForInput && continue ;;
             esac
             getBaseAddress ${reward_wallet}
             getBalance ${base_addr}
             if [[ ${lovelace} -gt 0 ]]; then
               println "DEBUG" "$(printf "%s\t${FG_CYAN}%s${NC} Ada" "Funds in reward wallet:"  "$(formatLovelace ${lovelace})")"
               echo
             else
               println "ERROR" "${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${reward_wallet}${NC}, needed to pay for registration fee"
               waitForInput && continue
             fi
             if ! registerStakeWallet ${reward_wallet}; then
               waitForInput && continue
             fi
           fi
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
    reward_stake_sk_file="${WALLET_FOLDER}/${reward_wallet}/${WALLET_STAKE_SK_FILENAME}"
    reward_delegation_cert_file="${WALLET_FOLDER}/${reward_wallet}/${WALLET_DELEGCERT_FILENAME}"

    pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
    pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
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
        getCurrentKESperiod
        echo "${current_kes_period}" > ${pool_saved_kes_start}
        println "ACTION" "${CCLI} node issue-op-cert --kes-verification-key-file \"${pool_hotkey_vk_file}\" --cold-signing-key-file \"${pool_coldkey_sk_file}\" --operational-certificate-issue-counter-file \"${pool_opcert_counter_file}\" --kes-period \"${current_kes_period}\" --out-file \"${pool_opcert_file}\""
        ${CCLI} node issue-op-cert --kes-verification-key-file "${pool_hotkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" --kes-period "${current_kes_period}" --out-file "${pool_opcert_file}"
      else
        println "DEBUG" "\n${FG_YELLOW}Pool operational certificate not generated in hybrid mode,"
        println "DEBUG" "please use 'Pool >> Rotate' in offline mode to generate new hot keys, op cert and KES start period and transfer to online node!${NC}"
        println "DEBUG" "Files generated when running 'Pool >> Rotate' to be transferred:"
        println "DEBUG" "${FG_CYAN}${pool_hotkey_vk_file}${NC}"
        println "DEBUG" "${FG_CYAN}${pool_hotkey_sk_file}${NC}"
        println "DEBUG" "${FG_CYAN}${pool_opcert_file}${NC}"
        println "DEBUG" "${FG_CYAN}${pool_saved_kes_start}${NC}"
        waitForInput "press any key to continue"
      fi
    fi

    println "LOG" "creating registration certificate"
    println "ACTION" "${CCLI} stake-pool registration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --vrf-verification-key-file ${pool_vrf_vk_file} --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file ${reward_stake_vk_file} --pool-owner-stake-verification-key-file ${owner_stake_vk_file} ${multi_owner_output} --metadata-url ${meta_json_url} --metadata-hash \$\(${CCLI} stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} \) ${relay_output} ${NETWORK_IDENTIFIER} --out-file ${pool_regcert_file}"
    ${CCLI} stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${reward_stake_vk_file}" --pool-owner-stake-verification-key-file "${owner_stake_vk_file}" ${multi_owner_output} --metadata-url "${meta_json_url}" --metadata-hash "$(${CCLI} stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} )" ${relay_output} ${NETWORK_IDENTIFIER} --out-file "${pool_regcert_file}"

    delegate_reward_wallet='N'
    delegate_owner_wallet='N'
    if [[ ${SUBCOMMAND} = "register" ]]; then
      if [[ ${hw_owner_wallets} = 'Y' || ${hw_reward_wallet} = 'Y' ]]; then
        println "DEBUG" "\n${FG_BLUE}INFO${NC}: hardware wallet included as reward or multi-owner, automatic owner/reward wallet delegation disabled"
        println "DEBUG" "${FG_BLUE}INFO${NC}: ${FG_YELLOW}please manually delegate all wallets to the pool!!!${NC}"
        waitForInput "press any key to continue"
      else
        println "LOG" "creating delegation certificate for main owner wallet"
        println "ACTION" "${CCLI} stake-address delegation-certificate --stake-verification-key-file ${owner_stake_vk_file} --cold-verification-key-file ${pool_coldkey_vk_file} --out-file ${owner_delegation_cert_file}"
        ${CCLI} stake-address delegation-certificate --stake-verification-key-file "${owner_stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${owner_delegation_cert_file}"
        delegate_owner_wallet='Y'
        if [[ "${owner_wallets[0]}" != "${reward_wallet}" ]]; then
          println "LOG" "creating delegation certificate for reward wallet"
          println "ACTION" "${CCLI} stake-address delegation-certificate --stake-verification-key-file ${reward_stake_vk_file} --cold-verification-key-file ${pool_coldkey_vk_file} --out-file ${reward_delegation_cert_file}"
          ${CCLI} stake-address delegation-certificate --stake-verification-key-file "${reward_stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${reward_delegation_cert_file}"
          delegate_reward_wallet='Y'
        fi
      fi
    fi
    
    if [[ ${SUBCOMMAND} = "register" ]]; then
      registerPool
      rc=$?
    else
      modifyPool
      rc=$?
    fi
    
    if [[ $rc -eq 0 ]]; then
      [[ -f "${pool_regcert_file}.tmp" ]] && rm -f "${pool_regcert_file}.tmp" # remove backup of old reg cert if it exist (modify)
      [[ -f "${pool_deregcert_file}" ]] && rm -f "${pool_deregcert_file}" # delete de-registration cert if available
    else # rc=1 failed | rc=2 used for offline mode, treat as failed for now, files written on submission
      [[ $rc -eq 1 ]] && echo && println "ERROR" "\n${FG_RED}ERROR${NC}: failure during pool ${SUBCOMMAND}!"
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
      printf '{"id":%s,"wallet_name":"%s"},\n' "${owner_array[@]}" | sed '$s/,$//'
      printf ']'
    } | jq -c .)
    echo "{\"owners\":$owner_json,\"rewardWallet\":\"$reward_wallet\",\"pledgeADA\":$pledge_ada,\"margin\":$margin,\"costADA\":$cost_ada,\"json_url\":\"$meta_json_url\",\"relays\": $relay_json}" > "${pool_config}"
    
    chmod 700 ${POOL_FOLDER}/${pool_name}/*

    [[ -f "${pool_deregcert_file}" ]] && rm -f ${pool_deregcert_file} # delete de-registration cert if available

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
      echo
      println "Pool ${FG_GREEN}${pool_name}${NC} built!"
      println "${FG_YELLOW}Follow the steps above to sign and submit transaction!${NC}"
    fi
    
    for index in "${!owner_wallets[@]}"; do
      println "Owner #$((index+1))      : ${FG_GREEN}${owner_wallets[${index}]}${NC}"
    done
    println "Reward Wallet : ${FG_GREEN}${reward_wallet}${NC}"
    println "Pledge        : $(formatAda ${pledge_ada}) Ada"
    println "Margin        : ${margin}%"
    println "Cost          : $(formatAda ${cost_ada}) Ada"
    if [[ ${SUBCOMMAND} = "register" ]]; then
      if [[ ${op_mode} = "hybrid" ]]; then
        println "DEBUG" "\n${FG_YELLOW}After offline pool transaction is signed and submitted, uncomment and set value for POOL_NAME in ${PARENT}/env with${NC} '${FG_GREEN}${pool_name}${NC}'"
      else
        println "DEBUG" "\n${FG_YELLOW}Uncomment and set value for POOL_NAME in ${PARENT}/env with${NC} '${FG_GREEN}${pool_name}${NC}'"
      fi
    fi
    echo
    if [[ ${op_mode} = "online" ]]; then
      total_pledge=0
      for wallet_name in "${owner_wallets[@]}"; do
        getBaseAddress ${wallet_name}
        getBalance ${base_addr}
        total_pledge=$(( total_pledge + lovelace ))
        getRewards ${wallet_name}
        [[ ${reward_lovelace} -gt 0 ]] && total_pledge=$(( total_pledge + reward_lovelace ))
      done
      println "DEBUG" "${FG_BLUE}INFO${NC}: Total balance in ${FG_CYAN}${#owner_wallets[@]}${NC} owner/pledge wallet(s) are: $(formatLovelace ${total_pledge}) Ada"
      if [[ ${total_pledge} -lt ${pledge_lovelace} ]]; then
        println "ERROR" "${FG_YELLOW}Not enough funds in owner/pledge wallet(s) to meet set pledge, please manually verify!!!${NC}"
      fi
    fi
    if [[ ${#owner_wallets[@]} -gt 1 ]]; then
      if [[ ${op_mode} = "hybrid" ]]; then
        println "DEBUG" "${FG_BLUE}INFO${NC}: please verify that all owner/reward wallets are delegated to the pool after the pool registration has been signed and submitted, if not do so!"
      else
        println "DEBUG" "${FG_BLUE}INFO${NC}: please verify that all owner/reward wallets are delegated to the pool, if not do so!"
      fi
    fi
    
    waitForInput && continue

    ;; ###################################################################

    retire)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> POOL >> RETIRE"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue
    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available to pay for pool de-registration!${NC}" && waitForInput && continue

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo

    println "DEBUG" "# Select pool to retire"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectPool "reg" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_COLDKEY_SK_FILENAME}"; then # ${pool_name} populated by selectPool function
        waitForInput && continue
      fi
    else
      if ! selectPool "reg" "${POOL_COLDKEY_VK_FILENAME}"; then # ${pool_name} populated by selectPool function
        waitForInput && continue
      fi
    fi
    echo

    epoch=$(getEpoch)
    eMax=$(jq -r '.eMax' "${TMP_FOLDER}"/protparams.json)

    println "DEBUG" "Current epoch: ${FG_CYAN}${epoch}${NC}"
    epoch_start=$((epoch + 1))
    epoch_end=$((epoch + eMax))
    println "DEBUG" "earlist epoch to retire pool is ${FG_CYAN}${epoch_start}${NC} and latest ${FG_CYAN}${epoch_end}${NC}"
    echo

    sleep 0.1 && read -r -p "Enter epoch in which to retire pool (blank for ${epoch_start}): " epoch_enter 2>&6 && println "LOG" "Enter epoch in which to retire pool (blank for ${epoch_start}): ${epoch_enter}"
    [[ -z "${epoch_enter}" ]] && epoch_enter=${epoch_start}
    echo

    if [[ ${epoch_enter} -lt ${epoch_start} || ${epoch_enter} -gt ${epoch_end} ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: epoch invalid, valid range: ${epoch_start}-${epoch_end}"
      waitForInput && continue
    fi
    
    println "DEBUG" "# Select wallet for pool de-registration transaction fee"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "balance" "${WALLET_PAY_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
      getWalletType ${wallet_name}
      case $? in
        0) println "ERROR" "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for pool de-registration transaction fee!" && waitForInput && continue ;;
        2) println "ERROR" "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
        3) println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
      esac
    else
      if ! selectWallet "balance" "${WALLET_PAY_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
      getWalletType ${wallet_name}
      case $? in
        0) println "ERROR" "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for pool de-registration transaction fee!" && waitForInput && continue ;;
      esac
    fi

    getBaseAddress ${wallet_name}
    getPayAddress ${wallet_name}
    getBalance ${base_addr}
    base_lovelace=${lovelace}
    getBalance ${pay_addr}
    pay_lovelace=${lovelace}

    if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
      # Both payment and base address available with funds, let user choose what to use
      println "DEBUG" "\n# Select wallet address to use"
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        println "DEBUG" "$(printf "%s\t\t${FG_CYAN}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
        println "DEBUG" "$(printf "%s\t${FG_CYAN}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
      fi
      select_opt "DEBUG" "[b] Base (default)" "[e] Enterprise" "[Esc] Cancel"
      case $? in
        0) addr="${base_addr}" ;;
        1) addr="${pay_addr}" ;;
        2) continue ;;
      esac
    elif [[ ${pay_lovelace} -gt 0 ]]; then
      addr="${pay_addr}"
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        println "DEBUG" "\n$(printf "%s\t${FG_CYAN}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
      fi
    elif [[ ${base_lovelace} -gt 0 ]]; then
      addr="${base_addr}"
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        println "DEBUG" "\n$(printf "%s\t\t${FG_CYAN}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
      fi
    else
      println "ERROR" "\n${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
      waitForInput && continue
    fi

    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_deregcert_file="${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}"
    pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"

    println "LOG" "creating de-registration cert"
    println "ACTION" "${CCLI} stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file}"
    ${CCLI} stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file}

    if ! deRegisterPool; then
      waitForInput && continue
    fi
    
    [[ -f "${pool_regcert_file}" ]] && rm -f ${pool_regcert_file} # delete registration cert
    
    echo
    if ! verifyTx ${addr}; then waitForInput && continue; fi
    
    echo
    println "Pool ${FG_GREEN}${pool_name}${NC} set to be retired in epoch ${FG_CYAN}${epoch_enter}${NC}"
    println "Pool deposit will be returned to owner reward address after its retired"

    waitForInput && continue

    ;; ###################################################################

    list)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> POOL >> LIST"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue

    while IFS= read -r -d '' pool; do
      echo
      getPoolID "$(basename ${pool})"
      pool_regcert_file="${pool}/${POOL_REGCERT_FILENAME}"
      pool_deregcert_file="${pool}/${POOL_DEREGCERT_FILENAME}"
      [[ -f "${pool_regcert_file}" ]] && pool_registered="${FG_GREEN}YES${NC}" || pool_registered="${FG_RED}NO${NC}"
      println "${FG_GREEN}$(basename ${pool})${NC} "
      println "$(printf "%-21s : %s" "ID (hex)" "${pool_id}")"
      [[ -n ${pool_id_bech32} ]] && println "$(printf "%-21s : %s" "ID (bech32)" "${pool_id_bech32}")"
      if [[ -f "${pool_deregcert_file}" ]]; then
        println "$(printf "%-21s : %s" "Registered" "${FG_RED}DE-REGISTERED${NC} - check 'Pool >> Show' for ledger registration status")"
      else
        println "$(printf "%-21s : %s" "Registered" "${pool_registered} - check 'Pool >> Show' for ledger registration status")"
      fi
      if [[ -f "${pool}/${POOL_CURRENT_KES_START}" ]]; then
        kesExpiration "$(cat "${pool}/${POOL_CURRENT_KES_START}")"
        if [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
          if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
            println "$(printf "%-21s : %s - ${FG_RED}%s${NC} %s ago" "KES expiration date" "${expiration_date}" "EXPIRED!" "$(showTimeLeft ${expiration_time_sec_diff:1})")"
          else
            println "$(printf "%-21s : %s - ${FG_RED}%s${NC} %s until expiration" "KES expiration date" "${expiration_date}" "ALERT!" "$(showTimeLeft ${expiration_time_sec_diff})")"
          fi
        elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
          println "$(printf "%-21s : %s - ${FG_YELLOW}%s${NC} %s until expiration" "KES expiration date" "${expiration_date}" "WARNING!" "$(showTimeLeft ${expiration_time_sec_diff})")"
        else
          println "$(printf "%-21s : %s" "KES expiration date" "${expiration_date}")"
        fi
      fi
    done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    echo

    waitForInput && continue

    ;; ###################################################################

    show)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> POOL >> SHOW"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "DEBUG" "${FG_CYAN}OFFLINE MODE${NC}: CNTools started in offline mode, locally saved info shown!"
    fi

    tput sc
    if ! selectPool "all" "${POOL_ID_FILENAME}"; then # ${pool_name} populated by selectPool function
      waitForInput && continue
    fi
    tput rc && tput ed

    if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
      tput sc && println "DEBUG" "Dumping ledger-state from node, can take a while on larger networks...\n"
      println "ACTION" "timeout -k 5 $TIMEOUT_LEDGER_STATE ${CCLI} query ledger-state ${ERA_IDENTIFIER} ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} --out-file \"${TMP_FOLDER}\"/ledger-state.json"
      if ! timeout -k 5 $TIMEOUT_LEDGER_STATE ${CCLI} query ledger-state ${ERA_IDENTIFIER} ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} --out-file "${TMP_FOLDER}"/ledger-state.json; then
        tput rc && tput ed
        println "ERROR" "${FG_RED}ERROR${NC}: ledger dump failed/timed out"
        println "ERROR" "increase timeout value in cntools.config"
        waitForInput && continue
      fi
      tput rc && tput ed
    fi

    getPoolID ${pool_name}
    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      [[ -f "${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}" ]] && pool_registered="YES" || pool_registered="NO"
      [[ -f "${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}" ]] && ledger_retiring="?" || ledger_retiring=""
    else
      tput sc && println "Parsing ledger-state, can take a while on larger networks...\n"
      ledger_pstate=$(jq -r '.nesEs.esLState._delegationState._pstate' "${TMP_FOLDER}"/ledger-state.json)
      ledger_pParams=$(jq -r '._pParams."'"${pool_id}"'" // empty' <<< ${ledger_pstate})
      ledger_fPParams=$(jq -r '._fPParams."'"${pool_id}"'" // empty' <<< ${ledger_pstate})
      ledger_retiring=$(jq -r '._retiring."'"${pool_id}"'" // empty' <<< ${ledger_pstate})
      [[ -z "${ledger_fPParams}" ]] && ledger_fPParams="${ledger_pParams}"
      [[ -n "${ledger_pParams}" ]] && pool_registered="YES" || pool_registered="NO"
      tput rc && tput ed
    fi
    echo
    println "$(printf "%-21s : ${FG_GREEN}%s${NC}" "Pool" "${pool_name}")"
    println "$(printf "%-21s : %s" "ID (hex)" "${pool_id}")"
    [[ -n ${pool_id_bech32} ]] && println "$(printf "%-21s : %s" "ID (bech32)" "${pool_id_bech32}")"
    [[ "${pool_registered}" = "YES" ]] && pool_reg_color="${FG_GREEN}" || pool_reg_color="${FG_RED}"
    if [[ -z "${ledger_retiring}" ]]; then
      println "$(printf "%-21s : ${pool_reg_color}%s${NC}" "Registered" "${pool_registered}")"
    else
      println "$(printf "%-21s : ${pool_reg_color}%s${NC} - ${FG_RED}Retired in epoch %s${NC}" "Registered" "${pool_registered}" "${ledger_retiring}")"
    fi
    pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta.json"
    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
    if [[ ${CNTOOLS_MODE} = "OFFLINE" && -f "${pool_meta_file}" ]]; then
      println "Metadata"
      println "$(printf "  %-19s : %s" "Name" "$(jq -r .name "${pool_meta_file}")")"
      println "$(printf "  %-19s : %s" "Ticker" "$(jq -r .ticker "${pool_meta_file}")")"
      println "$(printf "  %-19s : %s" "Homepage" "$(jq -r .homepage "${pool_meta_file}")")"
      println "$(printf "  %-19s : %s" "Description" "$(jq -r .description "${pool_meta_file}")")"
      [[ -f "${pool_config}" ]] && meta_url="$(jq -r .json_url "${pool_config}")" || meta_url="---"
      println "$(printf "  %-19s : %s" "URL" "${meta_url}")"
      println "ACTION" "${CCLI} stake-pool metadata-hash --pool-metadata-file \"${pool_meta_file}\""
      meta_hash="$( ${CCLI} stake-pool metadata-hash --pool-metadata-file "${pool_meta_file}" )"
      println "$(printf "  %-19s : %s" "Hash" "${meta_hash}")"
    else
      if [[ -f "${pool_config}" ]]; then
        meta_json_url=$(jq -r .json_url "${pool_config}")
      else
        meta_json_url=$(jq -r '.metadata.url //empty' <<< "${ledger_fPParams}")
      fi
      if [[ -n ${meta_json_url} ]] && curl -sL -m ${CURL_TIMEOUT} -o "${TMP_FOLDER}/url_poolmeta.json" ${meta_json_url}; then
        println "Metadata"
        println "$(printf "  %-19s : %s" "Name" "$(jq -r .name "$TMP_FOLDER/url_poolmeta.json")")"
        println "$(printf "  %-19s : %s" "Ticker" "$(jq -r .ticker "$TMP_FOLDER/url_poolmeta.json")")"
        println "$(printf "  %-19s : %s" "Homepage" "$(jq -r .homepage "$TMP_FOLDER/url_poolmeta.json")")"
        println "$(printf "  %-19s : %s" "Description" "$(jq -r .description "$TMP_FOLDER/url_poolmeta.json")")"
        println "$(printf "  %-19s : %s" "URL" "${meta_json_url}")"
        println "ACTION" "${CCLI} stake-pool metadata-hash --pool-metadata-file \"${TMP_FOLDER}/url_poolmeta.json\""
        meta_hash_url="$( ${CCLI} stake-pool metadata-hash --pool-metadata-file "${TMP_FOLDER}/url_poolmeta.json" )"
        meta_hash_pParams=$(jq -r '.metadata.hash //empty' <<< "${ledger_pParams}")
        meta_hash_fPParams=$(jq -r '.metadata.hash //empty' <<< "${ledger_fPParams}")
        println "$(printf "  %-19s : %s" "Hash URL" "${meta_hash_url}")"
        if [[ "${pool_registered}" = "YES" ]]; then
          if [[ "${meta_hash_pParams}" = "${meta_hash_fPParams}" ]]; then
            println "$(printf "  %-19s : %s" "Hash Ledger" "${meta_hash_pParams}")"
          else
            println "$(printf "  %-13s (${FG_YELLOW}%s${NC}) : %s" "Hash Ledger" "old" "${meta_hash_pParams}")"
            println "$(printf "  %-13s (${FG_YELLOW}%s${NC}) : %s" "Hash Ledger" "new" "${meta_hash_fPParams}")"
          fi
        fi
      else
        println "$(printf "%-21s : %s" "Metadata" "download failed for ${meta_json_url}")"
      fi
    fi
    if [[ "${pool_registered}" = "YES" ]]; then
      if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
        if [[ -f "${pool_config}" ]]; then
          conf_pledge=$(( $(jq -r '.pledgeADA //0' "${pool_config}") * 1000000 ))
          conf_margin=$(jq -r '.margin //0' "${pool_config}")
          conf_cost=$(( $(jq -r '.costADA //0' "${pool_config}") * 1000000 ))
          conf_owner=$(jq -r '.pledgeWallet //"unknown"' "${pool_config}")
          conf_reward=$(jq -r '.rewardWallet //"unknown"' "${pool_config}")
          println "$(printf "%-21s : %s Ada" "Pledge" "$(formatAda "${conf_pledge::-6}")")"
          println "$(printf "%-21s : %s %%" "Margin" "${conf_margin}")"
          println "$(printf "%-21s : %s Ada" "Cost" "$(formatAda "${conf_cost::-6}")")"
          println "$(printf "%-21s : %s (%s)" "Owner Wallet" "${FG_GREEN}${conf_owner}${NC}" "primary only, use online mode for multi-owner")"
          println "$(printf "%-21s : %s" "Reward Wallet" "${FG_GREEN}${conf_reward}${NC}")"
          relay_title="Relay(s)"
          while read -r type address port; do
            if [[ ${type} != "DNS_A" && ${type} != "IPv4" ]]; then
              println "$(printf "%-21s : %s" "${relay_title}" "unknown type (only IPv4/DNS supported in CNTools)")"
            else
              println "$(printf "%-21s : %s:%s" "${relay_title}" "${address}" "${port}")"
            fi
            relay_title=""
          done < <(jq -r '.relays[] | "\(.type) \(.address) \(.port)"' "${pool_config}")
        fi
      else
        pParams_pledge=$(jq -r '.pledge //0' <<< "${ledger_pParams}")
        fPParams_pledge=$(jq -r '.pledge //0' <<< "${ledger_fPParams}")
        if [[ ${pParams_pledge} -eq ${fPParams_pledge} ]]; then
          println "$(printf "%-21s : %s Ada" "Pledge" "$(formatAda "${pParams_pledge::-6}")")"
        else
          println "$(printf "%-15s (${FG_YELLOW}%s${NC}) : %s Ada" "Pledge" "new" "$(formatAda "${fPParams_pledge::-6}")" )"
        fi
        pParams_margin=$(LC_NUMERIC=C printf "%.4f" "$(jq -r '.margin //0' <<< "${ledger_pParams}")")
        fPParams_margin=$(LC_NUMERIC=C printf "%.4f" "$(jq -r '.margin //0' <<< "${ledger_fPParams}")")
        if [[ "${pParams_margin}" = "${fPParams_margin}" ]]; then
          println "$(printf "%-21s : %s %%" "Margin" "$(fractionToPCT "${pParams_margin}")")"
        else
          println "$(printf "%-15s (${FG_YELLOW}%s${NC}) : %s %%" "Margin" "new" "$(fractionToPCT "${fPParams_margin}")" )"
        fi
        pParams_cost=$(jq -r '.cost //0' <<< "${ledger_pParams}")
        fPParams_cost=$(jq -r '.cost //0' <<< "${ledger_fPParams}")
        if [[ ${pParams_cost} -eq ${fPParams_cost} ]]; then
          println "$(printf "%-21s : %s Ada" "Cost" "$(formatAda "${pParams_cost::-6}")")"
        else
          println "$(printf "%-15s (${FG_YELLOW}%s${NC}) : %s Ada" "Cost" "new" "$(formatAda "${fPParams_cost::-6}")" )"
        fi
        if [[ ! $(jq -c '.relays[] //empty' <<< "${ledger_pParams}") = $(jq -c '.relays[] //empty' <<< "${ledger_fPParams}") ]]; then
          println "$(printf "%-23s ${FG_YELLOW}%s${NC}" "" "Relay(s) updated, showing latest registered")"
        fi
        ledger_relays=$(jq -c '.relays[] //empty' <<< "${ledger_fPParams}")
        relay_title="Relay(s)"
        if [[ -n "${ledger_relays}" ]]; then
          while read -r relay; do
            relay_ipv4="$(jq -r '."single host address".IPv4 //empty' <<< ${relay})"
            relay_dns="$(jq -r '."single host name".dnsName //empty' <<< ${relay})"
            if [[ -n ${relay_ipv4} ]]; then
              relay_port="$(jq -r '."single host address".port //empty' <<< ${relay})"
              println "$(printf "%-21s : %s:%s" "${relay_title}" "${relay_ipv4}" "${relay_port}")"
            elif [[ -n ${relay_dns} ]]; then
              relay_port="$(jq -r '."single host name".port //empty' <<< ${relay})"
              println "$(printf "%-21s : %s:%s" "${relay_title}" "${relay_dns}" "${relay_port}")"
            else
              println "$(printf "%-21s : %s" "${relay_title}" "unknown type (only IPv4/DNS supported in CNTools)")"
            fi
            relay_title=""
          done <<< "${ledger_relays}"
        fi
        # get owners
        if [[ ! $(jq -c -r '.owners[] // empty' <<< "${ledger_pParams}") = $(jq -c -r '.owners[] // empty' <<< "${ledger_fPParams}") ]]; then
          println "$(printf "%-23s ${FG_YELLOW}%s${NC}" "" "Owner(s) updated, showing latest registered")"
        fi
        owner_title="Owner(s)"
        while read -r owner; do
          owner_wallet=$(grep -r ${owner} "${WALLET_FOLDER}" | head -1 | cut -d':' -f1)
          if [[ -n ${owner_wallet} ]]; then
            owner_wallet="$(basename "$(dirname "${owner_wallet}")")"
            println "$(printf "%-21s : %s" "${owner_title}" "${FG_GREEN}${owner_wallet}${NC}")"
          else
            println "$(printf "%-21s : %s" "${owner_title}" "${owner}")"
          fi
          owner_title=""
        done < <(jq -c -r '.owners[] // empty' <<< "${ledger_fPParams}")
        if [[ ! $(jq -r '.rewardAccount.credential."key hash" // empty' <<< "${ledger_pParams}") = $(jq -r '.rewardAccount.credential."key hash" // empty' <<< "${ledger_fPParams}") ]]; then
          println "$(printf "%-23s ${FG_YELLOW}%s${NC}" "" "Reward account updated, showing latest registered")"
        fi
        reward_account=$(jq -r '.rewardAccount.credential."key hash" // empty' <<< "${ledger_fPParams}")
        if [[ -n ${reward_account} ]]; then
          reward_wallet=$(grep -r ${reward_account} "${WALLET_FOLDER}" | head -1 | cut -d':' -f1)
          if [[ -n ${reward_wallet} ]]; then
            reward_wallet="$(basename "$(dirname "${reward_wallet}")")"
            println "$(printf "%-21s : %s" "Reward wallet" "${FG_GREEN}${reward_wallet}${NC}")"
          else
            println "$(printf "%-21s : %s" "Reward account" "${reward_account}")"
          fi
        fi
        println "ACTION" "LC_NUMERIC=C printf \"%.10f\" \"\$(${CCLI} query stake-distribution ${ERA_IDENTIFIER} ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} | grep \"${pool_id_bech32}\" | tr -s ' ' | cut -d ' ' -f 2)\")\""
        stake_pct=$(fractionToPCT "$(LC_NUMERIC=C printf "%.10f" "$(${CCLI} query stake-distribution ${ERA_IDENTIFIER} ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} | grep "${pool_id_bech32}" | tr -s ' ' | cut -d ' ' -f 2)")")
        if validateDecimalNbr ${stake_pct}; then
          println "$(printf "%-21s : %s %%" "Stake distribution" "${stake_pct}")"
        fi
      fi
      if [[ -f "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}" ]]; then
        kesExpiration "$(cat "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}")"
        if [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
          if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
            println "$(printf "%-21s : %s - ${FG_RED}%s${NC} %s ago" "KES expiration date" "${expiration_date}" "EXPIRED!" "$(showTimeLeft ${expiration_time_sec_diff:1})")"
          else
            println "$(printf "%-21s : %s - ${FG_RED}%s${NC} %s until expiration" "KES expiration date" "${expiration_date}" "ALERT!" "$(showTimeLeft ${expiration_time_sec_diff})")"
          fi
        elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
          println "$(printf "%-21s : %s - ${FG_YELLOW}%s${NC} %s until expiration" "KES expiration date" "${expiration_date}" "WARNING!" "$(showTimeLeft ${expiration_time_sec_diff})")"
        else
          println "$(printf "%-21s : %s" "KES expiration date" "${expiration_date}")"
        fi
      fi
    fi

    waitForInput && continue
    
    ;; ###################################################################

    rotate)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> POOL >> ROTATE KES"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    
    [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue
    
    println "DEBUG" "# Select pool to rotate KES keys on"
    if ! selectPool "all" "${POOL_COLDKEY_SK_FILENAME}" "${POOL_HOTKEY_SK_FILENAME}" "${POOL_HOTKEY_VK_FILENAME}" "${POOL_OPCERT_COUNTER_FILENAME}"; then # ${pool_name} populated by selectPool function
      waitForInput && continue
    fi

    if ! rotatePoolKeys; then
      waitForInput && continue
    fi

    echo
    println "Pool KES keys successfully updated"
    println "New KES start period  : ${current_kes_period}"
    println "KES keys will expire  : $(( current_kes_period + MAX_KES_EVOLUTIONS )) - ${expiration_date}"
    echo
    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "DEBUG" "Copy updated files to pool node replacing existing files:"
      println "DEBUG" "${pool_hotkey_sk_file}"
      println "DEBUG" "${pool_opcert_file}"
      echo
    fi
    println "DEBUG" "Restart your pool node for changes to take effect"

    waitForInput && continue

    ;; ###################################################################

    decrypt)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> POOL >> DECRYPT"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    
    [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue

    println "DEBUG" "# Select pool to decrypt"
    if ! selectPool "all"; then # ${pool_name} populated by selectPool function
      waitForInput && continue
    fi

    filesUnlocked=0
    keysDecrypted=0

    println "DEBUG" "# Removing write protection from all pool files"
    while IFS= read -r -d '' file; do
      if [[ ${ENABLE_CHATTR} = true && $(lsattr -R "$file") =~ -i- ]]; then
        sudo chattr -i "${file}"
      fi
      chmod 600 "${file}"
      filesUnlocked=$((++filesUnlocked))
      println "DEBUG" "${file}"
    done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    echo
    println "# Decrypting GPG encrypted pool files"
    echo
    if ! getPassword; then # $password variable populated by getPassword function
      println "\n\n" && println "ERROR" "${FG_RED}ERROR${NC}: password input aborted!"
      waitForInput && continue
    fi
    while IFS= read -r -d '' file; do
      decryptFile "${file}" "${password}" && \
      chmod 600 "${file::-4}" && \
      keysDecrypted=$((++keysDecrypted))
    done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
    unset password

    echo
    println "Pool decrypted:  ${FG_GREEN}${pool_name}${NC}"
    println "Files unlocked:  ${filesUnlocked}"
    println "Files decrypted: ${keysDecrypted}"
    if [[ ${filesUnlocked} -ne 0 || ${keysDecrypted} -ne 0 ]]; then
      echo
      println "DEBUG" "${FG_YELLOW}Pool files are now unprotected${NC}"
      println "DEBUG" "Use 'POOL >> ENCRYPT / LOCK' to re-lock"
    fi

    waitForInput && continue

    ;; ###################################################################

    encrypt)

    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> POOL >> ENCRYPT"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    
    [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No pools available!${NC}" && waitForInput && continue

    println "DEBUG" "# Select pool to encrypt"
    if ! selectPool "all"; then # ${pool_name} populated by selectPool function
      waitForInput && continue
    fi

    filesLocked=0
    keysEncrypted=0

    println "DEBUG" "# Encrypting sensitive pool keys with GPG"
    echo
    if ! getPassword confirm; then # $password variable populated by getPassword function
      println "\n\n" && println "ERROR" "${FG_RED}ERROR${NC}: password input aborted!"
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

    echo
    println "DEBUG" "# Write protecting all pool files with 400 permission and if enabled 'chattr +i'"
    while IFS= read -r -d '' file; do
      chmod 400 "$file"
      if [[ ${ENABLE_CHATTR} = true && ! $(lsattr -R "$file") =~ -i- ]]; then
        sudo chattr +i "$file"
      fi
      filesLocked=$((++filesLocked))
      println "DEBUG" "$file"
    done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    echo
    println "Pool encrypted:  ${FG_GREEN}${pool_name}${NC}"
    println "Files locked:    ${filesLocked}"
    println "Files encrypted: ${keysEncrypted}"
    if [[ ${filesLocked} -ne 0 || ${keysEncrypted} -ne 0 ]]; then
      echo
      println "DEBUG" "${FG_BLUE}INFO${NC}: pool files are now protected"
      println "DEBUG" "Use 'POOL >> DECRYPT / UNLOCK' to unlock"
    fi

    waitForInput && continue

    ;; ###################################################################

  esac
  
  ;; ###################################################################

  transaction)

  clear
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println " >> TRANSACTION"
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println "OFF" " Transaction Management\n\n"\
" ) Sign    - witness/sign offline tx with signing keys\n"\
" ) Submit  - submit signed offline tx to blockchain\n"\
"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println "DEBUG" " Select transaction operation\n"
  select_opt "[s] Sign" "[t] Submit" "[h] Home"
  case $? in
    0) SUBCOMMAND="sign" ;;
    1) SUBCOMMAND="submit" ;;
    2) continue ;;
  esac

  case $SUBCOMMAND in
    sign)
    
    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> TRANSACTION >> SIGN"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    [[ ${ENABLE_DIALOG} = "true" ]] && println "DEBUG" "Enter path to offline tx file to sign" && waitForInput "Press any key to open the file explorer"
    fileDialog "Enter path to offline tx file to sign" "${TMP_FOLDER}/"
    println "DEBUG" "${FG_CYAN}${file}${NC}\n"
    offline_tx=${file}
    [[ -z "${offline_tx}" ]] && continue
    if [[ ! -f "${offline_tx}" ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: file not found: ${offline_tx}"
      waitForInput && continue
    elif ! offlineJSON=$(jq -erc . "${offline_tx}"); then
      println "ERROR" "${FG_RED}ERROR${NC}: invalid JSON file: ${offline_tx}"
      waitForInput && continue
    fi
    
    if ! otx_type="$(jq -er '.type' <<< ${offlineJSON})"; then println "ERROR" "${FG_RED}ERROR${NC}: field 'type' not found in: ${offline_tx}" && waitForInput && continue; fi
    if ! otx_date_created="$(jq -er '."date-created"' <<< ${offlineJSON})"; then println "ERROR" "${FG_RED}ERROR${NC}: field 'date-created' not found in: ${offline_tx}" && waitForInput && continue; fi
    if ! otx_date_expire="$(jq -er '."date-expire"' <<< ${offlineJSON})"; then println "ERROR" "${FG_RED}ERROR${NC}: field 'date-expire' not found in: ${offline_tx}" && waitForInput && continue; fi
    if ! otx_txFee=$(jq -er '.txFee' <<< ${offlineJSON}); then println "ERROR" "${FG_RED}ERROR${NC}: field 'txFee' not found in: ${offline_tx}" && waitForInput && continue; fi
    if ! otx_txBody=$(jq -er '.txBody' <<< ${offlineJSON}); then println "ERROR" "${FG_RED}ERROR${NC}: field 'txBody' not found in: ${offline_tx}" && waitForInput && continue; fi
    echo -e "${otx_txBody}" > "${TMP_FOLDER}"/tx.raw
    [[ $(jq -r '."signed-txBody" | length' <<< ${offlineJSON}) -gt 0 ]] && println "ERROR" "${FG_RED}ERROR${NC}: transaction already signed, please submit transaction to complete!" && waitForInput && continue
    
    println "DEBUG" "Transaction type : ${FG_CYAN}${otx_type}${NC}"
    if wallet_name=$(jq -er '."wallet-name"' <<< ${offlineJSON}); then 
      println "DEBUG" "Transaction fee  : ${FG_CYAN}$(formatLovelace ${otx_txFee})${NC} Ada, payed by ${FG_GREEN}${wallet_name}${NC}"
      [[ $(cat "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}" 2>/dev/null) = "${addr}" ]] && wallet_source="enterprise" || wallet_source="base"
    else
      println "DEBUG" "Transaction fee  : ${FG_CYAN}$(formatLovelace ${otx_txFee})${NC} Ada"
    fi
    println "DEBUG" "Created          : ${FG_CYAN}$(date '+%F %T %Z' --date="${otx_date_created}")${NC}"
    if [[ $(date '+%s' --date="${otx_date_expire}") -lt $(date '+%s') ]]; then
      println "DEBUG" "Expire           : ${FG_RED}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}"
      println "ERROR" "\n${FG_RED}ERROR${NC}: offline transaction expired!  please create a new one with long enough Time To Live (TTL)"
      waitForInput && continue
    else
      println "DEBUG" "Expire           : ${FG_CYAN}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}"
    fi
    
    tx_witness_files=()
    tx_sign_files=()
    
    case "${otx_type}" in
      "Wallet Registration"|"Wallet De-Registration"|"Payment"|"Wallet Delegation"|"Wallet Rewards Withdrawal"|"Pool De-Registration"|"Metadata")
        [[ ${otx_type} = "Wallet De-Registration" ]] && println "DEBUG" "\nAmount returned  : ${FG_CYAN}$(formatLovelace "$(jq -r '."amount-returned"' <<< ${offlineJSON})")${NC} Ada"
        [[ ${otx_type} = "Payment" ]] && println "DEBUG" "\nSource addr      : ${FG_CYAN}$(jq -r '."source-address"' <<< ${offlineJSON})${NC}"
        [[ ${otx_type} = "Payment" ]] && println "DEBUG" "Amount           : ${FG_CYAN}$(formatLovelace "$(jq -r '.amount' <<< ${offlineJSON})")${NC} Ada"
        [[ ${otx_type} = "Payment" ]] && println "DEBUG" "Destination addr : ${FG_CYAN}$(jq -r '."destination-address"' <<< ${offlineJSON})${NC}"
        [[ ${otx_type} = "Wallet Rewards Withdrawal" ]] && println "DEBUG" "\nRewards          : ${FG_CYAN}$(formatLovelace "$(jq -r '.rewards' <<< ${offlineJSON})")${NC} Ada"
        [[ ${otx_type} = "Pool De-Registration" ]] && println "DEBUG" "\nPool name        : ${FG_CYAN}$(jq -r '."pool-name"' <<< ${offlineJSON})${NC}"
        [[ ${otx_type} = "Pool De-Registration" ]] && println "DEBUG" "Ticker           : ${FG_CYAN}$(jq -r '."pool-ticker"' <<< ${offlineJSON})${NC}"
        [[ ${otx_type} = "Pool De-Registration" ]] && println "DEBUG" "To be retired    : epoch ${FG_CYAN}$(jq -r '."retire-epoch"' <<< ${offlineJSON})${NC}"
        [[ ${otx_type} = "Metadata" ]] && println "DEBUG" "\nMetadata         :\n$(jq -r '.metadata' <<< ${offlineJSON})\n"
        for otx_signing_file in $(jq -r '."signing-file"[] | @base64' <<< "${offlineJSON}"); do
          _jq() { base64 -d <<< ${otx_signing_file} | jq -r "${1}"; }
          otx_signing_name=$(_jq '.name')
          println "DEBUG" "\n# Sign the transaction with: ${FG_CYAN}${otx_signing_name}${NC}"
          [[ ${ENABLE_DIALOG} = "true" ]] && waitForInput "Press any key to open the file explorer"
          [[ ${otx_signing_name} = "Wallet "* ]] && dialog_start_path="${WALLET_FOLDER}" || dialog_start_path="${POOL_FOLDER}"
          fileDialog "Enter path to ${otx_signing_name}" "${dialog_start_path}/"
          [[ ! -f "${file}" ]] && println "ERROR" "${FG_RED}ERROR${NC}: file not found: ${file}" && waitForInput && continue 2
          otx_vkey_cborHex="$(_jq '.vkey.cborHex')"
          if [[ $(jq -r '.description' "${file}") = *"Hardware"* ]]; then
            if ! grep -q "${otx_vkey_cborHex:4}" "${file}"; then # strip 5820 prefix
              println "ERROR" "${FG_RED}ERROR${NC}: signing key provided doesn't match with verification key in offline transaction for: ${otx_signing_name}"
              println "ERROR" "Provided hardware signing key's verification cborXPubKeyHex: $(jq -r .cborXPubKeyHex "${file}")"
              println "ERROR" "Transaction verification cborHex: ${otx_vkey_cborHex:4}"
              waitForInput && continue 2
            fi
          else
            println "ACTION" "${CCLI} key verification-key --signing-key-file ${file} --verification-key-file ${TMP_FOLDER}/vkey.tmp"
            if ! ${CCLI} key verification-key --signing-key-file "${file}" --verification-key-file "${TMP_FOLDER}"/vkey.tmp; then waitForInput && continue 2; fi
            if [[ ${otx_vkey_cborHex} != $(jq -r .cborHex "${TMP_FOLDER}"/vkey.tmp) ]]; then
              println "ERROR" "${FG_RED}ERROR${NC}: signing key provided doesn't match with verification key in offline transaction for: ${otx_signing_name}"
              println "ERROR" "Provided signing key's verification cborHex: $(jq -r .cborHex "${TMP_FOLDER}"/vkey.tmp)"
              println "ERROR" "Transaction verification cborHex: ${otx_vkey_cborHex}"
              waitForInput && continue 2
            fi
          fi
          println "DEBUG" "${FG_GREEN}Successfully added!${NC}"
          tx_sign_files+=( "${file}" )
        done
        if [[ ${#tx_sign_files[@]} -gt 0 ]]; then
          if ! signTx "${TMP_FOLDER}"/tx.raw "${tx_sign_files[@]}"; then waitForInput && continue; fi
          echo
          if jq ". += { \"signed-txBody\": $(jq -c . "${tx_signed}") }" <<< "${offlineJSON}" > "${offline_tx}"; then
            println "Offline transaction successfully signed, please move ${offline_tx} back to online node and submit before ${FG_CYAN}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}!"
          else
            println "ERROR" "${FG_RED}ERROR${NC}: failed to write signed tx body to offline transaction file!"
          fi
        else
          println "ERROR" "\n${FG_YELLOW}WARN${NC}: no signing keys added!"
        fi
        ;;
      "Pool Registration"|"Pool Update")
        echo
        println "DEBUG" "Pool name        : ${FG_CYAN}$(jq -r '."pool-metadata".name' <<< ${offlineJSON})${NC}"
        println "DEBUG" "Ticker           : ${FG_CYAN}$(jq -r '."pool-metadata".ticker' <<< ${offlineJSON})${NC}"
        println "DEBUG" "Pledge           : ${FG_CYAN}$(formatAda "$(jq -r '."pool-pledge"' <<< ${offlineJSON})")${NC} Ada"
        println "DEBUG" "Margin           : ${FG_CYAN}$(jq -r '."pool-margin"' <<< ${offlineJSON})${NC} %"
        println "DEBUG" "Cost             : ${FG_CYAN}$(formatAda "$(jq -r '."pool-cost"' <<< ${offlineJSON})")${NC} Ada"
        if ! otx_witness_era="$(jq -er '."witness-era"' <<< ${offlineJSON})"; then println "ERROR" "\n${FG_RED}ERROR${NC}: field 'witness-era' not found in: ${offline_tx}" && waitForInput && continue; fi
        for otx_signing_file in $(jq -r '."signing-file"[] | @base64' <<< "${offlineJSON}"); do
          _jq() { base64 -d <<< ${otx_signing_file} | jq -r "${1}"; }
          otx_signing_name=$(_jq '.name')
          for otx_witness in $(jq -r '.witness[] | @base64' <<< "${offlineJSON}"); do
            __jq() { base64 -d <<< ${otx_witness} | jq -r "${1}"; }
            [[ $(_jq '.name') = $(__jq '.name') ]] && continue 2 # offline transaction already witnessed by this signing key
          done
          println "DEBUG" "\nDo you want to sign ${otx_type} with: ${FG_CYAN}${otx_signing_name}${NC} ?"
          select_opt "[y] Yes" "[n] No"
          case $? in
            0) [[ ${otx_signing_name} = "Pool "* ]] && dialog_start_path="${POOL_FOLDER}" || dialog_start_path="${WALLET_FOLDER}"
               fileDialog "Enter path to ${otx_signing_name}" "${dialog_start_path}/"
               [[ ! -f "${file}" ]] && println "ERROR" "${FG_RED}ERROR${NC}: file not found: ${file}" && waitForInput && continue 2
               otx_vkey_cborHex="$(_jq '.vkey.cborHex')"
               if [[ $(jq -r '.description' "${file}") = *"Hardware"* ]]; then
                 if ! grep -q "${otx_vkey_cborHex:4}" "${file}"; then # strip 5820 prefix
                   println "ERROR" "${FG_RED}ERROR${NC}: signing key provided doesn't match with verification key in offline transaction for: ${otx_signing_name}"
                   println "ERROR" "Provided hardware signing key's verification cborXPubKeyHex: $(jq -r .cborXPubKeyHex "${file}")"
                   println "ERROR" "Transaction verification cborHex: ${otx_vkey_cborHex:4}"
                   waitForInput && continue 2
                 fi
               else
                 println "ACTION" "${CCLI} key verification-key --signing-key-file ${file} --verification-key-file ${TMP_FOLDER}/vkey.tmp"
                 if ! ${CCLI} key verification-key --signing-key-file "${file}" --verification-key-file "${TMP_FOLDER}"/vkey.tmp; then waitForInput && continue 2; fi
                 if [[ ${otx_vkey_cborHex} != $(jq -r .cborHex "${TMP_FOLDER}"/vkey.tmp) ]]; then
                   println "ERROR" "${FG_RED}ERROR${NC}: signing key provided doesn't match with verification key in offline transaction for: ${otx_signing_name}"
                   println "ERROR" "Provided signing key's verification cborHex: $(jq -r .cborHex "${TMP_FOLDER}"/vkey.tmp)"
                   println "ERROR" "Transaction verification cborHex: ${otx_vkey_cborHex}"
                   waitForInput && continue 2
                 fi
               fi
               if ! witnessTx "${TMP_FOLDER}/tx.raw" "${file}"; then waitForInput && continue 2; fi
               if ! offlineJSON=$(jq ".witness += [{ name: \"${otx_signing_name}\", witnessBody: $(jq -c . "${tx_witness_files[0]}") }]" <<< ${offlineJSON}); then return 1; fi
               jq -r . <<< "${offlineJSON}" > "${offline_tx}" # save this witness to disk
               ;;
            1) continue ;;
          esac
        done
        echo
        if [[ $(jq -r '."signing-file" | length' <<< "${offlineJSON}") -eq $(jq -r '.witness | length' <<< "${offlineJSON}") ]]; then # witnessed by all signing keys
          for otx_witness in $(jq -r '.witness[] | @base64' <<< "${offlineJSON}"); do
            _jq() { base64 -d <<< ${otx_witness} | jq -r "${1}"; }
            tx_witness="$(mktemp "${TMP_FOLDER}/tx.witness_XXXXXXXXXX")"
            jq -r . <<< "$(_jq '.witnessBody')" > "${tx_witness}"
            tx_witness_files+=( "${tx_witness}" )
          done
          if ! assembleTx "${TMP_FOLDER}/tx.raw"; then waitForInput && continue; fi
          if jq ". += { \"signed-txBody\": $(jq -c . "${tx_signed}") }" <<< "${offlineJSON}" > "${offline_tx}"; then
            println "Offline transaction successfully assembled and signed by all signing keys"
            println "please move ${offline_tx} back to online node and submit before ${FG_CYAN}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}!"
          else
            println "ERROR" "${FG_RED}ERROR${NC}: failed to write signed tx body to offline transaction file!"
          fi
        else
          println "Offline transaction need to be signed by ${FG_CYAN}$(jq -r '."signing-file" | length' <<< "${offlineJSON}")${NC} signing keys, signed by ${FG_CYAN}$(jq -r '.witness | length' <<< "${offlineJSON}")${NC} so far!"
        fi
        ;;
      *) println "ERROR" "${FG_RED}ERROR${NC}: unsupported offline tx type: ${otx_type}" && waitForInput && continue ;;
    esac
    
    waitForInput && continue

    ;; ###################################################################
    
    submit)
    
    clear
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> TRANSACTION >> SUBMIT"
    println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    fi
    echo
    [[ ${ENABLE_DIALOG} = "true" ]] && println "DEBUG" "Enter path to offline tx file to submit" && waitForInput "Press any key to open the file explorer"
    fileDialog "Enter path to offline tx file to submit" "${TMP_FOLDER}/"
    println "DEBUG" "${FG_CYAN}${file}${NC}\n"
    offline_tx=${file}
    [[ -z "${offline_tx}" ]] && continue
    if [[ ! -f "${offline_tx}" ]]; then
      println "ERROR" "${FG_RED}ERROR${NC}: file not found: ${offline_tx}"
      waitForInput && continue
    elif ! offlineJSON=$(jq -erc . "${offline_tx}"); then
      println "ERROR" "${FG_RED}ERROR${NC}: invalid JSON file: ${offline_tx}"
      waitForInput && continue
    fi
    
    if ! otx_type=$(jq -er '.type' <<< ${offlineJSON}); then println "ERROR" "${FG_RED}ERROR${NC}: field 'type' not found in: ${offline_tx}" && waitForInput && continue; fi
    if ! otx_date_created=$(jq -er '."date-created"' <<< ${offlineJSON}); then println "ERROR" "${FG_RED}ERROR${NC}: field 'date-created' not found in: ${offline_tx}" && waitForInput && continue; fi
    if ! otx_date_expire=$(jq -er '."date-expire"' <<< ${offlineJSON}); then println "ERROR" "${FG_RED}ERROR${NC}: field 'date-expire' not found in: ${offline_tx}" && waitForInput && continue; fi
    if ! otx_txFee=$(jq -er '.txFee' <<< ${offlineJSON}); then println "ERROR" "${FG_RED}ERROR${NC}: field 'txFee' not found in: ${offline_tx}" && waitForInput && continue; fi
    if ! otx_signed_txBody=$(jq -er '."signed-txBody"' <<< ${offlineJSON}); then println "ERROR" "${FG_RED}ERROR${NC}: field 'signed-txBody' not found in: ${offline_tx}" && waitForInput && continue; fi
    [[ $(jq 'length' <<< ${otx_signed_txBody}) -eq 0 ]] && println "ERROR" "${FG_RED}ERROR${NC}: transaction not signed, please sign transaction first!" && waitForInput && continue
    
    println "DEBUG" "Transaction type : ${FG_CYAN}${otx_type}${NC}"
    if jq -er '."wallet-name"' &>/dev/null <<< ${offlineJSON}; then 
      println "DEBUG" "Transaction fee  : ${FG_CYAN}$(formatLovelace ${otx_txFee})${NC} Ada, payed by ${FG_GREEN}$(jq -r '."wallet-name"' <<< ${offlineJSON})${NC}"
    else
      println "DEBUG" "Transaction fee  : ${FG_CYAN}$(formatLovelace ${otx_txFee})${NC} Ada"
    fi
    println "DEBUG" "Created          : ${FG_CYAN}$(date '+%F %T %Z' --date="${otx_date_created}")${NC}"
    if [[ $(date '+%s' --date="${otx_date_expire}") -lt $(date '+%s') ]]; then
      println "DEBUG" "Expire           : ${FG_RED}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}"
      println "ERROR" "\n${FG_RED}ERROR${NC}: offline transaction expired!  please create a new one with long enough Time To Live (TTL)"
      waitForInput && continue
    else
      println "DEBUG" "Expire           : ${FG_CYAN}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}"
    fi
    
    case "${otx_type}" in
      "Wallet Registration"|"Wallet De-Registration"|"Payment"|"Wallet Delegation"|"Wallet Rewards Withdrawal"|"Pool De-Registration"|"Metadata"|"Pool Registration"|"Pool Update")
        [[ ${otx_type} = "Wallet De-Registration" ]] && println "DEBUG" "\nAmount returned  : ${FG_CYAN}$(formatLovelace "$(jq -r '."amount-returned"' <<< ${offlineJSON})")${NC} Ada"
        [[ ${otx_type} = "Payment" ]] && println "DEBUG" "\nSource addr      : ${FG_CYAN}$(jq -r '."source-address"' <<< ${offlineJSON})${NC}"
        [[ ${otx_type} = "Payment" ]] && println "DEBUG" "Amount           : ${FG_CYAN}$(formatLovelace "$(jq -r '.amount' <<< ${offlineJSON})")${NC} Ada"
        [[ ${otx_type} = "Payment" ]] && println "DEBUG" "Destination addr : ${FG_CYAN}$(jq -r '."destination-address"' <<< ${offlineJSON})${NC}"
        [[ ${otx_type} = "Wallet Rewards Withdrawal" ]] && println "DEBUG" "\nRewards          : ${FG_CYAN}$(formatLovelace "$(jq -r '.rewards' <<< ${offlineJSON})")${NC} Ada"
        [[ ${otx_type} = "Pool De-Registration" ]] && println "DEBUG" "\nPool name        : ${FG_CYAN}$(jq -r '."pool-name"' <<< ${offlineJSON})${NC}"
        [[ ${otx_type} = "Pool De-Registration" ]] && println "DEBUG" "Ticker           : ${FG_CYAN}$(jq -r '."pool-ticker"' <<< ${offlineJSON})${NC}"
        [[ ${otx_type} = "Pool De-Registration" ]] && println "DEBUG" "To be retired    : epoch ${FG_CYAN}$(jq -r '."retire-epoch"' <<< ${offlineJSON})${NC}"
        [[ ${otx_type} = "Metadata" ]] && println "DEBUG" "\nMetadata         :\n$(jq -r '.metadata' <<< ${offlineJSON})\n"
        [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println "DEBUG" "\nPool name        : ${FG_CYAN}$(jq -r '."pool-metadata".name' <<< ${offlineJSON})${NC}"
        [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println "DEBUG" "Ticker           : ${FG_CYAN}$(jq -r '."pool-metadata".ticker' <<< ${offlineJSON})${NC}"
        [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println "DEBUG" "Pledge           : ${FG_CYAN}$(formatAda "$(jq -r '."pool-pledge"' <<< ${offlineJSON})")${NC} Ada"
        [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println "DEBUG" "Margin           : ${FG_CYAN}$(jq -r '."pool-margin"' <<< ${offlineJSON})${NC} %"
        [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println "DEBUG" "Cost             : ${FG_CYAN}$(formatAda "$(jq -r '."pool-cost"' <<< ${offlineJSON})")${NC} Ada"
        
        tx_signed="${TMP_FOLDER}/tx.signed_$(date +%s)"
        
        println "DEBUG" "\nProceed to submit transaction?"
        select_opt "[y] Yes" "[n] No"
        case $? in
          0) : ;;
          1) continue ;;
        esac
        echo -e "${otx_signed_txBody}" > "${tx_signed}"
        if ! submitTx "${tx_signed}"; then waitForInput && continue; fi
        
        if [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]]; then
          if otx_pool_name=$(jq -er '."pool-name"' <<< ${offlineJSON}); then
            if ! jq '."pool-reg-cert"' <<< "${offlineJSON}" > "${POOL_FOLDER}/${otx_pool_name}/${POOL_REGCERT_FILENAME}"; then println "ERROR" "${FG_RED}ERROR${NC}: failed to write pool cert to disk"; fi
            [[ -f "${POOL_FOLDER}/${otx_pool_name}/${POOL_DEREGCERT_FILENAME}" ]] && rm -f "${POOL_FOLDER}/${otx_pool_name}/${POOL_DEREGCERT_FILENAME}" # delete de-registration cert if available
          else
            println "ERROR" "${FG_RED}ERROR${NC}: field 'pool-name' not found in: ${offline_tx}"
          fi
        fi
        
        echo
        println "Offline transaction successfully submitted and set to be included in next block!"
        echo 
        println "DEBUG" "Delete submitted offline transaction file?"
        select_opt "[y] Yes" "[n] No"
        case $? in
          0) rm -f "${offline_tx}" ;;
          1) : ;;
        esac
        ;;
      *) println "ERROR" "${FG_RED}ERROR${NC}: unsupported offline tx type: ${otx_type}" && waitForInput && continue ;;
    esac
    
    waitForInput && continue

    ;; ###################################################################
    
  esac
  
  ;; ###################################################################
  
  metadata)

  clear
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println " >> FUNDS >> POST METADATA"
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  
  [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available to pay for transaction fee!${NC}" && waitForInput && continue

  if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
    println "ERROR" "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
    waitForInput && continue
  else
    if ! selectOpMode; then continue; fi
  fi
  echo
  
  println "DEBUG" "Select the type of metadata to post on-chain"
  println "DEBUG" "ref: https://github.com/input-output-hk/cardano-node/blob/master/doc/reference/tx-metadata.md"
  select_opt "[n] No JSON Schema (default)" "[d] Detailed JSON Schema" "[c] Raw CBOR"
  case $? in
    0) metatype="no-schema" ;;
    1) metatype="detailed-schema" ;;
    2) metatype="cbor" ;;
  esac

  if [[ ${metatype} = "cbor" ]]; then
    fileDialog "Enter path to raw CBOR metadata file"
    metafile="${file}"
    println "DEBUG" "${metafile}\n"
  else
    metafile="${TMP_FOLDER}/metadata.json"
    println "DEBUG" "\nDo you want to select a metadata file, enter URL to metadata file, or enter/paste metadata content?"
    select_opt "[f] File" "[u] URL" "[e] Enter"
    case $? in
      0) tput sc
         fileDialog "Enter path to JSON metadata file"
         metafile="${file}"
         if [[ ! -f "${metafile}" ]] || ! jq -er . "${metafile}" &>/dev/null; then
           println "ERROR" "${FG_RED}ERROR${NC}: invalid JSON format or file not found"
           println "ERROR" "${metafile}"
           waitForInput && continue
         fi
         tput rc && tput ed
         println "DEBUG" "${metafile}:\n$(cat "${metafile}")\n"
         ;;
      1) tput sc && echo
         sleep 0.1 && read -r -p "Enter URL to JSON metadata file: " meta_json_url 2>&6 && println "LOG" "Enter URL to JSON metadata file: ${meta_json_url}"
         if [[ ! "${meta_json_url}" =~ https?://.* ]]; then
           println "ERROR" "${FG_RED}ERROR${NC}: invalid URL format"
           waitForInput && continue
         fi
         if ! curl -sL -m ${CURL_TIMEOUT} -o "${metafile}" ${meta_json_url} || ! jq -er . "${metafile}" &>/dev/null; then
           println "ERROR" "${FG_RED}ERROR${NC}: metadata download failed, please make sure the URL point to a valid JSON file!"
           waitForInput && continue
         fi
         tput rc && tput ed
         println "Metadata file successfully downloaded to: ${metafile}"
         ;;
      2) tput sc
         DEFAULTEDITOR="$(command -v nano &>/dev/null && echo 'nano' || echo 'vi')"
         println "OFF" "\nPaste or enter the metadata text, opening text editor ${FG_CYAN}${DEFAULTEDITOR}${NC}"
         println "OFF" "${FG_YELLOW}Please don't change default file path when saving${NC}"
         waitForInput "press any key to open ${DEFAULTEDITOR}"
         ${DEFAULTEDITOR} "${metafile}"
         if [[ ! -f "${metafile}" ]] || ! jq -er . "${metafile}" &>/dev/null; then
           println "ERROR" "${FG_RED}ERROR${NC}: invalid JSON format or file not found"
           println "ERROR" "${metafile}"
           waitForInput && continue
         fi
         tput rc && tput ed
         println "Metadata file successfully saved to: ${metafile}"
         ;;
    esac
  fi

  println "DEBUG" "\n# Select wallet"
  if [[ ${op_mode} = "online" ]]; then
    if ! selectWallet "balance" "${WALLET_PAY_SK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
    fi
    getWalletType ${wallet_name}
    case $? in
      0) println "ERROR" "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for metadata transaction fee!" && waitForInput && continue ;;
      2) println "ERROR" "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitForInput && continue ;;
      3) println "ERROR" "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitForInput && continue ;;
    esac
  else
    if ! selectWallet "balance"; then # ${wallet_name} populated by selectWallet function
      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
    fi
    getWalletType ${wallet_name}
    case $? in
      0) println "ERROR" "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for metadata transaction fee!" && waitForInput && continue ;;
    esac
  fi
  echo

  getBaseAddress ${wallet_name}
  getPayAddress ${wallet_name}
  getBalance ${base_addr}
  base_lovelace=${lovelace}
  getBalance ${pay_addr}
  pay_lovelace=${lovelace}

  if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
    # Both payment and base address available with funds, let user choose what to use
    println "DEBUG" "Select source wallet address"
    if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
      println "DEBUG" "$(printf "%s\t\t${FG_CYAN}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
      println "DEBUG" "$(printf "%s\t${FG_CYAN}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
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
      println "DEBUG" "$(printf "%s\t${FG_CYAN}%s${NC} Ada" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")"
    fi
  elif [[ ${base_lovelace} -gt 0 ]]; then
    addr="${base_addr}"
    if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
      println "DEBUG" "$(printf "%s\t\t${FG_CYAN}%s${NC} Ada" "Funds :"  "$(formatLovelace ${base_lovelace})")"
    fi
  else
    println "ERROR" "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
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

  blocks)

  clear
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println " >> BLOCKS"
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

  if [[ ! -f "${BLOCKLOG_DB}" ]]; then
    println "ERROR" "${FG_RED}ERROR${NC}: blocklog db not found: ${BLOCKLOG_DB}"
    println "ERROR" "please follow instructions at guild website to deploy CNCLI and logMonitor services"
    println "ERROR" "https://cardano-community.github.io/guild-operators/#/Scripts/cncli"
    waitForInput && continue
  elif ! command -v sqlite3 >/dev/null; then
    println "ERROR" "${FG_RED}ERROR${NC}: sqlite3 not found!"
    println "ERROR" "please also follow instructions at guild website to deploy CNCLI and logMonitor services"
    println "ERROR" "https://cardano-community.github.io/guild-operators/#/Scripts/cncli"
    waitForInput && continue
  fi
  current_epoch=$(getEpoch)
  println "DEBUG" "Current epoch: ${FG_CYAN}${current_epoch}${NC}\n"
  println "DEBUG" "Show a block summary for all epochs or a detailed view for a specific epoch?"
  select_opt "[s] Summary" "[e] Epoch" "[Esc] Cancel"
  case $? in
    0) echo && sleep 0.1 && read -r -p "Enter number of epochs to show (enter for 10): " epoch_enter 2>&6 && println "LOG" "Enter number of epochs to show (enter for 10): ${epoch_enter}"
       epoch_enter=${epoch_enter:-10}
       if ! [[ ${epoch_enter} =~ ^[0-9]+$ ]]; then
         println "ERROR" "\n${FG_RED}ERROR${NC}: not a number"
         waitForInput && continue
       fi
       view=1; view_output="${FG_CYAN}[b] Block View${NC} | [i] Info"
       while true; do
         clear
         println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
         println " >> BLOCKS"
         println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
         current_epoch=$(getEpoch)
         println "DEBUG" "Current epoch: ${FG_CYAN}${current_epoch}${NC}\n"
         if [[ ${view} -eq 1 ]]; then
           [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=$((current_epoch+1)) LIMIT 1);" 2>/dev/null) -eq 1 ]] && ((current_epoch++))
           first_epoch=$(( current_epoch - epoch_enter ))
           [[ ${first_epoch} -lt 0 ]] && first_epoch=0
           
           ideal_len=$(sqlite3 "${BLOCKLOG_DB}" "SELECT LENGTH(epoch_slots_ideal) FROM epochdata WHERE epoch BETWEEN ${first_epoch} and ${current_epoch} ORDER BY LENGTH(epoch_slots_ideal) DESC LIMIT 1;")
           [[ ${ideal_len} -lt 5 ]] && ideal_len=5
           luck_len=$(sqlite3 "${BLOCKLOG_DB}" "SELECT LENGTH(max_performance) FROM epochdata WHERE epoch BETWEEN ${first_epoch} and ${current_epoch} ORDER BY LENGTH(max_performance) DESC LIMIT 1;")
           [[ $((luck_len+1)) -le 4 ]] && luck_len=4 || luck_len=$((luck_len+1))
           printf '|' >&3; printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" | tr " " "=" >&3; printf '|\n' >&3
           printf "| %-5s | %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_CYAN}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "Epoch" "Leader" "Ideal" "Luck" "Adopted" "Confirmed" "Missed" "Ghosted" "Stolen" "Invalid" >&3
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
             printf "| %-5s | %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_CYAN}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "${current_epoch}" "${leader_cnt}" "${epoch_stats[0]}" "${epoch_stats[1]}" "${adopted_cnt}" "${confirmed_cnt}" "${missed_cnt}" "${ghosted_cnt}" "${stolen_cnt}" "${invalid_cnt}" >&3
             ((current_epoch--))
           done
           printf '|' >&3; printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" | tr " " "=" >&3; printf '|\n' >&3
         else
           println "OFF" "Block Status:\n"
           println "OFF" "Leader    - Scheduled to make block at this slot"
           println "OFF" "Ideal     - Expected/Ideal number of blocks assigned based on active stake (sigma)"
           println "OFF" "Luck      - Leader slots assigned vs Ideal slots for this epoch"
           println "OFF" "Adopted   - Block created successfully"
           println "OFF" "Confirmed - Block created validated to be on-chain with the certainty"
           println "OFF" "            set in 'cncli.sh' for 'CONFIRM_BLOCK_CNT'"
           println "OFF" "Missed    - Scheduled at slot but no record of it in cncli DB and no"
           println "OFF" "            other pool has made a block for this slot"
           println "OFF" "Ghosted   - Block created but marked as orphaned and no other pool has made"
           println "OFF" "            a valid block for this slot, height battle or block propagation issue"
           println "OFF" "Stolen    - Another pool has a valid block registered on-chain for the same slot"
           println "OFF" "Invalid   - Pool failed to create block, base64 encoded error message"
           println "OFF" "            can be decoded with 'echo <base64 hash> | base64 -d | jq -r'"
         fi
         echo
         
         println "OFF" "[h] Home | ${view_output} | [*] Refresh"
         read -rsn1 key
         case ${key} in
           h ) continue 2 ;;
           b ) view=1; view_output="${FG_CYAN}[b] Block View${NC} | [i] Info" ;;
           i ) view=2; view_output="[b] Block View | ${FG_CYAN}[i] Info${NC}" ;;
           * ) continue ;;
         esac
       done
       ;;
    1) [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=$((current_epoch+1)) LIMIT 1);" 2>/dev/null) -eq 1 ]] && println "DEBUG" "\n${FG_YELLOW}Leader schedule for next epoch[$((current_epoch+1))] available${NC}"
       echo && sleep 0.1 && read -r -p "Enter epoch to list (enter for current): " epoch_enter 2>&6 && println "LOG" "Enter epoch to list (enter for current): ${epoch_enter}"
       [[ -z "${epoch_enter}" ]] && epoch_enter=${current_epoch}
       if [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=${epoch_enter} LIMIT 1);" 2>/dev/null) -eq 0 ]]; then
         println "No blocks in epoch ${epoch_enter}"
         waitForInput && continue
       fi
       view=1; view_output="${FG_CYAN}[1] View 1${NC} | [2] View 2 | [3] View 3 | [i] Info"
       while true; do
         clear
         println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
         println " >> BLOCKS"
         println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
         current_epoch=$(getEpoch)
         println "DEBUG" "Current epoch: ${FG_CYAN}${current_epoch}${NC}\n"
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
         printf "| %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_CYAN}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "Leader" "Ideal" "Luck" "Adopted" "Confirmed" "Missed" "Ghosted" "Stolen" "Invalid" >&3
         printf '|' >&3; printf "%$((6+ideal_len+luck_len+7+9+6+7+6+7+24+2))s" | tr " " "=" >&3; printf '|\n' >&3
         printf "| %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_CYAN}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "${leader_cnt}" "${epoch_stats[0]}" "${epoch_stats[1]}" "${adopted_cnt}" "${confirmed_cnt}" "${missed_cnt}" "${ghosted_cnt}" "${stolen_cnt}" "${invalid_cnt}" >&3
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
         at_len=23
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
             printf "| %-${#leader_cnt}s | %-${status_len}s | %-${block_len}s | %-${slot_len}s | %-${slot_in_epoch_len}s | %-${at_len}s |\n" "${block_cnt}" "${status}" "${block}" "${slot}" "${slot_in_epoch}" "${at}" >&3
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
             printf "| %-${#leader_cnt}s | %-${status_len}s | %-${slot_len}s | %-${size_len}s | %-${hash_len}s |\n" "${block_cnt}" "${status}" "${slot}" "${size}" "${hash}" >&3
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
             printf "| %-${#leader_cnt}s | %-${status_len}s | %-${block_len}s | %-${slot_len}s | %-${slot_in_epoch_len}s | %-${at_len}s | %-${size_len}s | %-${hash_len}s |\n" "${block_cnt}" "${status}" "${block}" "${slot}" "${slot_in_epoch}" "${at}" "${size}" "${hash}" >&3
             ((block_cnt++))
           done < <(sqlite3 "${BLOCKLOG_DB}" "SELECT status, block, slot, slot_in_epoch, at, size, hash FROM blocklog WHERE epoch=${epoch_enter} ORDER BY slot;" 2>/dev/null)
           printf '|' >&3; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+size_len+hash_len+23))s" | tr " " "=" >&3; printf '|\n' >&3
         elif [[ ${view} -eq 4 ]]; then
           println "OFF" "Block Status:\n"
           println "OFF" "Leader    - Scheduled to make block at this slot"
           println "OFF" "Ideal     - Expected/Ideal number of blocks assigned based on active stake (sigma)"
           println "OFF" "Luck      - Leader slots assigned vs Ideal slots for this epoch"
           println "OFF" "Adopted   - Block created successfully"
           println "OFF" "Confirmed - Block created validated to be on-chain with the certainty"
           println "OFF" "            set in 'cncli.sh' for 'CONFIRM_BLOCK_CNT'"
           println "OFF" "Missed    - Scheduled at slot but no record of it in cncli DB and no"
           println "OFF" "            other pool has made a block for this slot"
           println "OFF" "Ghosted   - Block created but marked as orphaned and no other pool has made"
           println "OFF" "            a valid block for this slot, height battle or block propagation issue"
           println "OFF" "Stolen    - Another pool has a valid block registered on-chain for the same slot"
           println "OFF" "Invalid   - Pool failed to create block, base64 encoded error message"
           println "OFF" "            can be decoded with 'echo <base64 hash> | base64 -d | jq -r'"
         fi
         echo
         
         println "OFF" "[h] Home | ${view_output} | [*] Refresh"
         read -rsn1 key
         case ${key} in
           h ) continue 2 ;;
           1 ) view=1; view_output="${FG_CYAN}[1] View 1${NC} | [2] View 2 | [3] View 3 | [i] Info" ;;
           2 ) view=2; view_output="[1] View 1 | ${FG_CYAN}[2] View 2${NC} | [3] View 3 | [i] Info" ;;
           3 ) view=3; view_output="[1] View 1 | [2] View 2 | ${FG_CYAN}[3] View 3${NC} | [i] Info" ;;
           i ) view=4; view_output="[1] View 1 | [2] View 2 | [3] View 3 | ${FG_CYAN}[i] Info${NC}" ;;
           * ) continue ;;
         esac
       done
       ;;
    2) continue ;;
  esac

  waitForInput && continue

  ;; ###################################################################

  update)

  clear
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println " >> UPDATE"
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo
  println "DEBUG" "Full changelog available at:\nhttps://cardano-community.github.io/guild-operators/#/Scripts/cntools-changelog"
  echo

  if curl -s -m ${CURL_TIMEOUT} -o "${TMP_FOLDER}"/cntools.library "${URL}/cntools.library"; then
    GIT_MAJOR_VERSION=$(grep -r ^CNTOOLS_MAJOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    GIT_MINOR_VERSION=$(grep -r ^CNTOOLS_MINOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    GIT_PATCH_VERSION=$(grep -r ^CNTOOLS_PATCH_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    GIT_VERSION="${GIT_MAJOR_VERSION}.${GIT_MINOR_VERSION}.${GIT_PATCH_VERSION}"
    if [[ ${CNTOOLS_MAJOR_VERSION} -lt ${GIT_MAJOR_VERSION} ]]; then
      println "DEBUG" "New major version available: ${FG_GREEN}${GIT_VERSION}${NC} (Current: ${CNTOOLS_VERSION})\n"
      println "DEBUG" "${FG_RED}WARNING${NC}: Breaking changes were made to CNTools!"
      println "DEBUG" "\nPlease read changelog available at the above URL carefully and then follow directions below"
      waitForInput "We will not overwrite your changes automatically, press any key for update instructions"
      println "DEBUG" "\n\n1) Please use the built in Backup option in CNTools before proceeding"
      println "DEBUG" "\n2) After backup, re-run updated prereqs.sh script with appropriate arguments, info and directions available at:"
      println "DEBUG" "   https://cardano-community.github.io/guild-operators/#/basics?id=pre-requisites"
      println "DEBUG" "\n3) As the last step, restore any modified parameters in cntools.config / env if needed"
    elif ! versionCheck "${GIT_VERSION}" "${CNTOOLS_VERSION}"; then
      if [[ "${GIT_PATCH_VERSION}" -eq 999  ]]; then
        ((GIT_MAJOR_VERSION++))
        GIT_MINOR_VERSION=0
        GIT_PATCH_VERSION=0
      fi
      println "DEBUG" "New version available: ${FG_GREEN}${GIT_MAJOR_VERSION}.${GIT_MINOR_VERSION}.${GIT_PATCH_VERSION}${NC} (Current: ${CNTOOLS_VERSION})\n"
      println "DEBUG" "${FG_BLUE}INFO${NC} - the following files will be overwritten:"
      println "DEBUG" "${PARENT}/cntools.sh"
      println "DEBUG" "${PARENT}/cntools.library"
      println "DEBUG" "\nProceed with update?"
      select_opt "[y] Yes" "[n] No"
      case $? in
        0) : ;; # do nothing
        1) continue ;; 
      esac
      println "\nApplying update..."
      if curl -s -m ${CURL_TIMEOUT} -o "${PARENT}/cntools.sh.tmp" "${URL}/cntools.sh" &&
         curl -s -m ${CURL_TIMEOUT} -o "${PARENT}/cntools.library.tmp" "${URL}/cntools.library" &&
         [[ $(grep "_HOME=" "${PARENT}"/env) =~ ^#?([^[:space:]]+)_HOME ]] &&
         sed -e "s@[C]NODE_HOME@${BASH_REMATCH[1]}_HOME@g" -i "${PARENT}/cntools".*.tmp; then
        mv -f "${PARENT}/cntools.sh.tmp" "${PARENT}/cntools.sh"
        mv -f "${PARENT}/cntools.library.tmp" "${PARENT}/cntools.library"
        chmod 755 "${PARENT}/cntools.sh"
        println "Update applied successfully!"
        myExit 0 "Update applied successfully!\n\nPlease start CNTools again!"
      else
        println "ERROR" "\n${FG_RED}ERROR${NC}: update failed! :(\n"
      fi
    else
      println "${FG_GREEN}Up to Date${NC}: You're using the latest version. No updates required!"
    fi
  else
    println "ERROR" "\n${FG_RED}ERROR${NC}: download from GitHub failed, unable to perform version check!\n"
  fi
  
  waitForInput && continue
  
  ;; ###################################################################

  backup)

  clear
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println " >> BACKUP & RESTORE"
  println "DEBUG" "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo
  println "DEBUG" "Create or restore a backup of CNTools wallets, pools and configuration files"
  echo
  println "DEBUG" "Backup or Restore?"
  select_opt "[b] Backup" "[r] Restore" "[Esc] Cancel"
  case $? in
    0) echo
       [[ ${ENABLE_DIALOG} = "true" ]] && println "DEBUG" "Enter backup directory (created if non existent)" && waitForInput "Press any key to open the file explorer"
       dirDialog "Enter backup directory (created if non existent)"
       [[ "${dir}" != */ ]] && backup_path="${dir}/" || backup_path="${dir}"
       println "DEBUG" "${FG_GREEN}${backup_path}${NC}\n"
       if [[ ! "${backup_path}" =~ ^/[-0-9A-Za-z_]+ ]]; then
         println "ERROR" "${FG_RED}ERROR${NC}: invalid path, please specify the full path to backup directory (space not allowed)"
         waitForInput && continue
       fi
       mkdir -p "${backup_path}" # Create if missing
       if [[ ! -d "${backup_path}" ]]; then
         println "ERROR" "${FG_RED}ERROR${NC}: failed to create backup directory:"
         println "ERROR" "${backup_path}"
         waitForInput && continue
       fi
       
       missing_keys="false"
       excluded_files=()
       println "DEBUG" "Include private keys in backup?"
       println "DEBUG" "- No  > create a backup excluding wallets ${WALLET_PAY_SK_FILENAME}/${WALLET_STAKE_SK_FILENAME} and pools ${POOL_COLDKEY_SK_FILENAME}"
       println "DEBUG" "- Yes > create a backup including all available files"
       select_opt "[n] No" "[y] Yes"
       case $? in
         0) excluded_files=(
              "--delete *${WALLET_PAY_SK_FILENAME}"
              "--delete *${WALLET_STAKE_SK_FILENAME}"
              "--delete *${POOL_COLDKEY_SK_FILENAME}"
            )
            backup_file="${backup_path}online_cntools_backup-$(date '+%Y%m%d%H%M%S').tar"
            ;;
         1) backup_file="${backup_path}offline_cntools_backup-$(date '+%Y%m%d%H%M%S').tar" ;;
       esac
       echo
       
       backup_list=(
         "${WALLET_FOLDER}"
         "${POOL_FOLDER}"
         "${BLOCKLOG_DIR}"
         "${CNODE_HOME}/files"
         "${CNODE_HOME}/scripts"
       )
       println "DEBUG" "Backup job include:"
       for item in "${backup_list[@]}"; do
         println "DEBUG" "${item}"
       done
       echo

       if ! tar cf "${backup_file}" --files-from <(ls -d "${backup_list[@]}" 2>/dev/null) &>/dev/null; then
         println "ERROR" "${FG_RED}ERROR${NC}: failure during backup creation :("
         waitForInput && continue
       fi
       if [[ ${#excluded_files[@]} -gt 0 ]]; then
         tar --wildcards --file="${backup_file}" ${excluded_files[*]} &>/dev/null
         gzip "${backup_file}" && backup_file+=".gz"
       else
         gzip "${backup_file}" && backup_file+=".gz"
         while IFS= read -r -d '' wallet; do # check for missing signing keys
           wallet_name=$(basename ${wallet})
           [[ -z "$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f \( -name "${WALLET_PAY_SK_FILENAME}*" -o -name "${WALLET_HW_PAY_SK_FILENAME}" \) -print)" ]] && \
             println "${FG_YELLOW}WARN${NC}: Wallet ${FG_GREEN}${wallet_name}${NC} missing payment signing key file" && missing_keys="true"
           [[ -z "$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f \( -name "${WALLET_STAKE_SK_FILENAME}*" -o -name "${WALLET_HW_STAKE_SK_FILENAME}" \) -print)" ]] && \
             println "${FG_YELLOW}WARN${NC}: Wallet ${FG_GREEN}${wallet_name}${NC} missing stake signing key file" && missing_keys="true"
         done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
         while IFS= read -r -d '' pool; do
           pool_name=$(basename ${pool})
           [[ -z "$(find "${pool}" -mindepth 1 -maxdepth 1 -type f -name "${POOL_COLDKEY_SK_FILENAME}*" -print)" ]] && \
             println "${FG_YELLOW}WARN${NC}: Pool ${FG_GREEN}${pool_name}${NC} missing file ${POOL_COLDKEY_SK_FILENAME}" && missing_keys="true"
         done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
         [[ ${missing_keys} = "true" ]] && echo
         println "DEBUG" "Do you want to delete private keys?"
         select_opt "[n] No" "[y] Yes"
         case $? in
           0) : ;; # do nothing
           1) while IFS= read -r -d '' file; do
                safeDel "${file}"
              done < <(find "${WALLET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${WALLET_PAY_SK_FILENAME}*" -print0)
              while IFS= read -r -d '' file; do
                safeDel "${file}"
              done < <(find "${WALLET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${WALLET_STAKE_SK_FILENAME}*" -print0)
              while IFS= read -r -d '' file; do
                safeDel "${file}"
              done < <(find "${POOL_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${POOL_COLDKEY_SK_FILENAME}*" -print0)
              ;;
         esac
         echo
       fi
       
       println "DEBUG" "Encrypt backup?"
       select_opt "[y] Yes" "[n] No"
       case $? in
         0) echo
            if getPassword confirm; then # $password variable populated by getPassword function
              encryptFile "${backup_file}" "${password}"
              backup_file="${backup_file}.gpg"
              unset password
            else
              println "ERROR" "\n${FG_RED}ERROR${NC}: password input aborted!"
            fi
            ;;
         1) : ;; # do nothing
       esac
       
       echo
       if [[ ${missing_keys} = "true" ]]; then
         println "DEBUG" "${FG_YELLOW}There are wallets and/or pools with missing keys.\nIf removed in a previous backup, make sure to keep that master backup safe!${NC}"
         println "\nIncremental backup file ${backup_file} successfully created"
       else
         println "Backup file ${backup_file} successfully created"
       fi
       ;;
    1) println "DEBUG" "\nBackups created contain absolute path to files and directories"
       println "DEBUG" "Restoring a backup does not replace existing files"
       println "DEBUG" "Please restore to a temporary directory and copy files to restore to appropriate folders\n"
       [[ ${ENABLE_DIALOG} = "true" ]] && println "DEBUG" "Enter file to restore" && waitForInput "Press any key to open the file explorer"
       fileDialog "Enter backup file to restore"
       backup_file=${file}
       if [[ ! -f "${backup_file}" ]]; then
         println "ERROR" "${FG_RED}ERROR${NC}: file not found: ${backup_file}"
         waitForInput && continue
       fi
       println "DEBUG" "${FG_GREEN}${backup_file}${NC}\n"
       [[ ${ENABLE_DIALOG} = "true" ]] && println "DEBUG" "Enter restore directory (created if non existent)" && waitForInput "Press any key to open the file explorer"
       dirDialog "Enter restore directory (created if non existent)"
       [[ "${dir}" != */ ]] && restore_path="${dir}/" || restore_path="${dir}"
       if [[ ! "${restore_path}" =~ ^/[-0-9A-Za-z_]+ ]]; then
         println "ERROR" "${FG_RED}ERROR${NC}: invalid path, please specify the full path to restore directory (space not allowed):"
         println "ERROR" "${restore_path}"
         waitForInput && continue
       fi
       println "DEBUG" "${FG_GREEN}${restore_path}${NC}"
       restore_path="${restore_path}$(basename ${backup_file%%.*})"
       mkdir -p "${restore_path}" # Create restore directory
       if [[ ! -d "${restore_path}" ]]; then
         println "ERROR" "\n${FG_RED}ERROR${NC}: failed to create restore directory:"
         println "ERROR" "${restore_path}"
         waitForInput && continue
       fi
       if [ "${backup_file##*.}" = "gpg" ]; then
         println "DEBUG" "\nBackup GPG encrypted, enter password to decrypt"
         if getPassword; then # $password variable populated by getPassword function
           decryptFile "${backup_file}" "${password}"
           backup_file="${backup_file%.*}"
           unset password
         else
           println "ERROR" "\n${FG_RED}ERROR${NC}: password input aborted!"
           waitForInput && continue
         fi
       fi
       if ! tar xfzk "${backup_file}" -C "${restore_path}" >/dev/null; then
         println "ERROR" "${FG_RED}ERROR${NC}: failure during backup restore :("
         waitForInput && continue
       fi
       println "\nBackup successfully restored to ${restore_path}"
       ;;
    2) continue ;;
  esac
  
  waitForInput && continue

  ;; ###################################################################

esac # main OPERATION
done # main loop
}

##############################################################

main "$@"
