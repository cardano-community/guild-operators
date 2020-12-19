#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2154,SC2034,SC2012

########## Global tasks ###########################################

# General exit handler
cleanup() {
  [[ -n $1 ]] && err=$1 || err=$?
  clear
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
[[ -f "${CNODE_HOME}"/scripts/.env_branch ]] && BRANCH="$(cat ${CNODE_HOME}/scripts/.env_branch)" || BRANCH="master"

while getopts :ob: opt; do
  case ${opt} in
    o ) CNTOOLS_MODE="OFFLINE" ;;
    b ) BRANCH=${OPTARG}; echo "${BRANCH}" > "${CNODE_HOME}"/scripts/.env_branch ;;
    \? ) myExit 1 "$(usage)" ;;
    esac
done
shift $((OPTIND -1))

# get common env variables
if ! . "${CNODE_HOME}"/scripts/env; then
  [[ ${CNTOOLS_MODE} = "CONNECTED" ]] && exit 1
  myExit 1 "\nERROR: CNTools run in offline mode and failed to automatically grab common env variables\nPlease uncomment all variables in 'User Variables' section and set values manually\n"
fi

# get cntools config parameters
. "${CNODE_HOME}"/scripts/cntools.config

# get helper functions from library file
. "${CNODE_HOME}"/scripts/cntools.library

URL_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}"
URL="${URL_RAW}/scripts/cnode-helper-scripts"
URL_DOCS="${URL_RAW}/docs/Scripts"

# create temporary directory if missing
mkdir -p "${TMP_FOLDER}" # Create if missing
if [[ ! -d "${TMP_FOLDER}" ]]; then
  myExit 1 "${FG_RED}ERROR${NC}: Failed to create directory for temporary files:\n${TMP_FOLDER}"
fi

# check for required command line tools
if ! need_cmd "curl" || \
   ! need_cmd "jq" || \
   ! need_cmd "bc" || \
   ! need_cmd "sed" || \
   ! need_cmd "awk" || \
   ! need_cmd "column" || \
   ! protectionPreRequisites; then waitForInput "Missing one or more of the required command line tools, press any key to exit"; myExit 1
fi

# Do some checks when run in connected mode
if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
  # check to see if there are any updates available
  clear
  say "CNTools version check...\n"
  if curl -s -m ${CURL_TIMEOUT} -o "${TMP_FOLDER}"/cntools.library "${URL}/cntools.library" && [[ -f "${TMP_FOLDER}"/cntools.library ]]; then
    GIT_MAJOR_VERSION=$(grep -r ^CNTOOLS_MAJOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    GIT_MINOR_VERSION=$(grep -r ^CNTOOLS_MINOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    GIT_PATCH_VERSION=$(grep -r ^CNTOOLS_PATCH_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    if [[ "$GIT_PATCH_VERSION" -eq 999  ]]; then
      ((GIT_MAJOR_VERSION++))
      GIT_MINOR_VERSION=0
      GIT_PATCH_VERSION=0
    fi
    if [[ "$CNTOOLS_PATCH_VERSION" -eq 999  ]]; then
      # CNTools was updated using special 999 patch tag, apply correct version in cntools.library and update variables already sourced
      sed -i "s/CNTOOLS_MAJOR_VERSION=[[:digit:]]\+/CNTOOLS_MAJOR_VERSION=$((++CNTOOLS_MAJOR_VERSION))/" "$CNODE_HOME/scripts/cntools.library"
      sed -i "s/CNTOOLS_MINOR_VERSION=[[:digit:]]\+/CNTOOLS_MINOR_VERSION=0/" "$CNODE_HOME/scripts/cntools.library"
      sed -i "s/CNTOOLS_PATCH_VERSION=[[:digit:]]\+/CNTOOLS_PATCH_VERSION=0/" "$CNODE_HOME/scripts/cntools.library"
      # CNTOOLS_MAJOR_VERSION variable already updated in sed replace command
      CNTOOLS_MINOR_VERSION=0
      CNTOOLS_PATCH_VERSION=0
      CNTOOLS_VERSION="${CNTOOLS_MAJOR_VERSION}.${CNTOOLS_MINOR_VERSION}.${CNTOOLS_PATCH_VERSION}"
    fi
    if [[ "${CNTOOLS_MAJOR_VERSION}" != "${GIT_MAJOR_VERSION}" || "${CNTOOLS_MINOR_VERSION}" != "${GIT_MINOR_VERSION}" || "${CNTOOLS_PATCH_VERSION}" != "${GIT_PATCH_VERSION}" ]]; then
      say "A new version of CNTools is available" "log"
      echo
      say "Installed Version : ${CNTOOLS_VERSION}" "log"
      say "Available Version : ${FG_GREEN}${GIT_MAJOR_VERSION}.${GIT_MINOR_VERSION}.${GIT_PATCH_VERSION}${NC}" "log"
      say "\nGo to Update section for upgrade\n\nAlternately, follow https://cardano-community.github.io/guild-operators/#/basics?id=pre-requisites to update cntools as well alongwith any other files"
      waitForInput "press any key to proceed"
    else
      # check if CNTools was recently updated, if so show whats new
      if curl -s -m ${CURL_TIMEOUT} -o "${TMP_FOLDER}"/cntools-changelog.md "${URL_DOCS}/cntools-changelog.md"; then
        if ! cmp -s "${TMP_FOLDER}"/cntools-changelog.md "$CNODE_HOME/scripts/cntools-changelog.md"; then
          # Latest changes not shown, show whats new and copy changelog
          clear 
          say "~ CNTools - What's New ~"
          if [[ ! -f "$CNODE_HOME/scripts/cntools-changelog.md" ]]; then 
            # special case for first installation or 5.0.0 upgrade, print release notes until previous major version
            waitForInput "Press any key to show what's new in last major release, use 'q' to quit viewer"
            clear
            sed -n "/\[${CNTOOLS_MAJOR_VERSION}\.${CNTOOLS_MINOR_VERSION}\.${CNTOOLS_PATCH_VERSION}\]/,/\[$((CNTOOLS_MAJOR_VERSION-1))\.[0-9]\.[0-9]\]/p" "${TMP_FOLDER}"/cntools-changelog.md | head -n -2 | less -X
          else
            # print release notes from current until previously installed version
            waitForInput "Press any key to show what's new compared to currently installed release, use 'q' to quit viewer"
            clear
            [[ $(cat "$CNODE_HOME/scripts/cntools-changelog.md") =~ \[([[:digit:]])\.([[:digit:]])\.([[:digit:]])\] ]]
            sed -n "/\[${CNTOOLS_MAJOR_VERSION}\.${CNTOOLS_MINOR_VERSION}\.${CNTOOLS_PATCH_VERSION}\]/,/\[${BASH_REMATCH[1]}\.${BASH_REMATCH[2]}\.${BASH_REMATCH[3]}\]/p" "${TMP_FOLDER}"/cntools-changelog.md | head -n -2 | less -X
          fi
          cp "${TMP_FOLDER}"/cntools-changelog.md "$CNODE_HOME/scripts/cntools-changelog.md"
        fi
      else
        say "\n${FG_RED}ERROR${NC}: failed to download changelog from GitHub!\n"
        waitForInput "press any key to proceed"
      fi
    fi
  else
    say "\n${FG_RED}ERROR${NC}: failed to download cntools.library from GitHub, unable to perform version check!\n"
    waitForInput "press any key to proceed"
  fi

  # Validate protocol parameters
  if grep -q "Network.Socket.connect" <<< "${PROT_PARAMS}"; then
    myExit 1 "${FG_YELLOW}WARN${NC}: node socket path wrongly configured or node not running, please verify that socket set in env file match what is used to run the node\n\n\
${FG_BLUE}Re-run CNTools in offline mode with -o parameter if you want to access CNTools with limited functionality${NC}"
  elif [[ -z "${PROT_PARAMS}" ]] || ! jq -er . <<< "${PROT_PARAMS}" &>/dev/null; then
    myExit 1 "${FG_YELLOW}WARN${NC}: failed to query protocol parameters, ensure your node is running with correct genesis (the node needs to be in sync to 1 epoch after the hardfork)\n\n\
Error message: ${PROT_PARAMS}\n\n\
${FG_BLUE}Re-run CNTools in offline mode with -o parameter if you want to access CNTools with limited functionality${NC}"
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
      say "\n** WARNING **\nPool ${FG_GREEN}$(basename ${pool})${NC} in need of KES key rotation"
      if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
        say "${FG_RED}Keys expired!${NC} : ${FG_RED}$(showTimeLeft ${expiration_time_sec_diff:1})${NC} ago"
      else
        say "Remaining KES periods : ${FG_RED}${remaining_kes_periods}${NC}"
        say "Time left             : ${FG_RED}$(showTimeLeft ${expiration_time_sec_diff})${NC}"
      fi
    elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
      kes_rotation_needed="yes"
      say "\nPool ${FG_GREEN}$(basename ${pool})${NC} soon in need of KES key rotation"
      say "Remaining KES periods : ${FG_YELLOW}${remaining_kes_periods}${NC}"
      say "Time left             : ${FG_YELLOW}$(showTimeLeft ${expiration_time_sec_diff})${NC}"
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
find "${TMP_FOLDER:?}" -type f -not \( -name 'protparams.json' -o -name '.dialogrc' \) -delete

clear
if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
  say "$(printf " >> CNTools v%s - ${FG_GREEN}%s${NC} << %$((84-20-${#CNTOOLS_VERSION}-${#CNTOOLS_MODE}))s" "${CNTOOLS_VERSION}" "${CNTOOLS_MODE}" "A Guild Operators collaboration")" "log"
else
  say "$(printf " >> CNTools v%s - ${FG_CYAN}%s${NC} << %$((84-20-${#CNTOOLS_VERSION}-${#CNTOOLS_MODE}))s" "${CNTOOLS_VERSION}" "${CNTOOLS_MODE}" "A Guild Operators collaboration")" "log"
fi
say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
say " Main Menu"
echo
say " ) Wallet    -  create, show, remove and protect wallets"
say " ) Funds     -  send, withdraw and delegate"
say " ) Pool      -  pool creation and management"
say " ) Sign Tx   -  Sign a built transaction file (hybrid/offline mode)"
say " ) Submit Tx -  Submit a signed transaction file (hybrid/offline mode)"
say " ) Metadata  -  Post metadata on-chain (e.g voting)"
say " ) Blocks    -  show core node leader slots"
say " ) Update    -  update cntools script and library config files"
say " ) Backup    -  backup & restore of wallet/pool/config"
say " ) Refresh   -  reload home screen content"
say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
say "$(printf "%84s" "Epoch $(getEpoch) - $(timeUntilNextEpoch) until next")"
if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
  say " What would you like to do?"
else
  tip_diff=$(getSlotTipDiff)
  slot_interval=$(slotInterval)
  if [[ ${tip_diff} -le ${slot_interval} ]]; then
    say "$(printf " What would you like to do? %$((84-29-${#tip_diff}-3))s ${FG_GREEN}%s${NC}" "Node Sync:" "${tip_diff} :)")"
  elif [[ ${tip_diff} -le $(( slot_interval * 2 )) ]]; then
    say "$(printf " What would you like to do? %$((84-29-${#tip_diff}-3))s ${FG_YELLOW}%s${NC}" "Node Sync:" "${tip_diff} :|")"
  else
    say "$(printf " What would you like to do? %$((84-29-${#tip_diff}-3))s ${FG_RED}%s${NC}" "Node Sync:" "${tip_diff} :(")"
  fi
fi
echo
select_opt "[w] Wallet" "[f] Funds" "[p] Pool" "[s] Sign Tx" "[t] Submit Tx" "[m] Metadata" "[b] Blocks" "[u] Update" "[z] Backup & Restore" "[r] Refresh" "[q] Quit"
case $? in
  0) OPERATION="wallet" ;;
  1) OPERATION="funds" ;;
  2) OPERATION="pool" ;;
  3) OPERATION="signTx" ;;
  4) OPERATION="submitTx" ;;
  5) OPERATION="metadata" ;;
  6) OPERATION="blocks" ;;
  7) OPERATION="update" ;;
  8) OPERATION="backup" ;;
  9) continue ;;
  10) myExit 0 "CNTools closed!" ;;
esac

case $OPERATION in
  wallet)

  clear
  say " >> WALLET" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  say " Wallet Management"
  echo
  say " ) New        -  create a new wallet"
  say " ) Import     -  import a Daedalus/Yoroi 24 or 15 word Shelley mnemonic created wallet"
  say " ) Register   -  register a wallet on chain"
  say " ) De-Register -  De-Register (retire) a registered wallet"
  say " ) List       -  list all available wallets in a compact view"
  say " ) Show       -  show detailed view of a specific wallet"
  say " ) Remove     -  remove a wallet"
  say " ) Decrypt    -  remove write protection and decrypt wallet"
  say " ) Encrypt    -  encrypt wallet keys and make all files immutable"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

  say " Select Wallet operation\n"
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
    say " >> WALLET >> NEW" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    read -r -p "Name of new wallet: " wallet_name
    # Remove unwanted characters from wallet name
    wallet_name=${wallet_name//[^[:alnum:]]/_}
    if [[ -z "${wallet_name}" ]]; then
      say "${FG_RED}ERROR${NC}: Empty wallet name, please retry!"
      waitForInput && continue
    fi
    echo
    if ! mkdir -p "${WALLET_FOLDER}/${wallet_name}"; then
      say "${FG_RED}ERROR${NC}: Failed to create directory for wallet:\n${WALLET_FOLDER}/${wallet_name}"
      waitForInput && continue
    fi

    # Wallet key filenames
    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"

    if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -type f -print0 | wc -c) -gt 0 ]]; then
      say "${FG_RED}WARN${NC}: A wallet ${FG_GREEN}$wallet_name${NC} already exists"
      say "      Choose another name or delete the existing one"
      waitForInput && continue
    fi

    ${CCLI} address key-gen --verification-key-file "${payment_vk_file}" --signing-key-file "${payment_sk_file}"
    ${CCLI} stake-address key-gen --verification-key-file "${stake_vk_file}" --signing-key-file "${stake_sk_file}"
    chmod 700 ${WALLET_FOLDER}/${wallet_name}/*
    getBaseAddress ${wallet_name}
    getPayAddress ${wallet_name}
    getRewardAddress ${wallet_name}

    say "New Wallet          : ${FG_GREEN}${wallet_name}${NC}" "log"
    say "Address             : ${base_addr}" "log"
    say "Enterprise Address  : ${pay_addr}" "log"
    say "\nYou can now send and receive ADA using the above addresses."
    say "Note that Enterprise Address will not take part in staking."
    say "Wallet will be automatically registered on chain if you\nchoose to delegate or pledge wallet when registering a stake pool."
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput && continue

    ;; ###################################################################
    
    import)

    clear
    say " >> WALLET >> IMPORT" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    
    if ! need_cmd "bech32" || \
       ! need_cmd "cardano-address"; then
      say "${FG_RED}ERROR${NC}: cardano-address and/or bech32 executables not found in path!"
      say "Please run updated prereqs.sh and re-build cardano-node"
      waitForInput && continue
    fi
    
    read -r -p "Name of imported wallet: " wallet_name
    # Remove unwanted characters from wallet name
    wallet_name=${wallet_name//[^[:alnum:]]/_}
    if [[ -z "${wallet_name}" ]]; then
      say "${FG_RED}ERROR${NC}: Empty wallet name, please retry!"
      waitForInput && continue
    fi
    echo
    if ! mkdir -p "${WALLET_FOLDER}/${wallet_name}"; then
      say "${FG_RED}ERROR${NC}: Failed to create directory for wallet:\n${WALLET_FOLDER}/${wallet_name}"
      waitForInput && continue
    fi
    
    if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -type f -print0 | wc -c) -gt 0 ]]; then
      say "${FG_RED}WARN${NC}: A wallet ${FG_GREEN}$wallet_name${NC} already exists"
      say "      Choose another name or delete the existing one"
      waitForInput && continue
    fi
    
    read -r -p "24 or 15 word mnemonic(space separated): " mnemonic
    echo
    IFS=" " read -r -a words <<< "${mnemonic}"
    if [[ ${#words[@]} -ne 24 ]] && [[ ${#words[@]} -ne 15 ]]; then
      say "${FG_RED}ERROR${NC}: 24 or 15 words expected, found ${FG_RED}${#words[@]}${NC}"
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
      say "TestNet, converting address to 'addr_test'" 1
      base_addr_candidate=$(bech32 addr_test <<< ${base_addr_candidate})
    fi
    say "Base address candidate = ${base_addr_candidate}" 2
    say "Generated from 1852H/1815H/0H/0/0" 2
    say "Address Inspection:\n$(cardano-address address inspect <<< ${base_addr_candidate})" 2
    
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
    
    ${CCLI} key verification-key --signing-key-file "${payment_sk_file}" --verification-key-file "${TMP_FOLDER}"/payment.evkey
    ${CCLI} key verification-key --signing-key-file "${stake_sk_file}" --verification-key-file "${TMP_FOLDER}"/stake.evkey

    ${CCLI} key non-extended-key --extended-verification-key-file "${TMP_FOLDER}"/payment.evkey --verification-key-file "${payment_vk_file}"
    ${CCLI} key non-extended-key --extended-verification-key-file "${TMP_FOLDER}"/stake.evkey --verification-key-file "${stake_vk_file}"
    chmod 700 ${WALLET_FOLDER}/${wallet_name}/*

    getBaseAddress ${wallet_name}
    getPayAddress ${wallet_name}
    getRewardAddress ${wallet_name}
    
    if [[ ${base_addr} != "${base_addr_candidate}" ]]; then
      say "${FG_RED}ERROR${NC}: base address generated doesn't match base address candidate."
      say "base_addr[${FG_CYAN}${base_addr}${NC}]\n!=\nbase_addr_candidate[${FG_CYAN}${base_addr_candidate}${NC}]" 1
      say "Run CNTools in verbose mode(VERBOSITY=2) and paste output to a GitHub issue."
      echo && safeDel "${WALLET_FOLDER}/${wallet_name}"
      waitForInput && continue
    fi
    
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    say "Wallet Imported     : ${FG_GREEN}${wallet_name}${NC}" "log"
    say "Address             : ${base_addr}" "log"
    say "Enterprise Address  : ${pay_addr}" "log"
    echo
    say "You can now send and receive ADA using the above addresses. Note that Enterprise Address will not take part in staking"
    say "Wallet will be automatically registered on chain if you choose to delegate or pledge wallet when registering a stake pool"
    echo
    say "${FG_YELLOW}Using a mnemonic imported wallet in CNTools comes with a few limitation.${NC}"
    echo
    say "Only the first address in the HD wallet is extracted and because of this the following apply:"
    say " ${FG_CYAN}>${NC} Address above should match the first address seen in Daedalus/Yoroi, please verify!!!"
    say " ${FG_CYAN}>${NC} If restored wallet contain funds since before, send all Ada through Daedalus/Yoroi to address shown in CNTools"
    say " ${FG_CYAN}>${NC} Only use receive address shown in CNTools"
    say " ${FG_CYAN}>${NC} Only spend Ada from CNTools, if spent through Daedalus/Yoroi balance seen in CNTools wont match"
    echo
    say "Some of the advantages of using a mnemonic imported wallet instead of CLI are:"
    say " ${FG_CYAN}>${NC} Wallet can be restored from saved 24 or 15 word mnemonic if keys are lost/deleted"
    say " ${FG_CYAN}>${NC} Track rewards in Daedalus/Yoroi"
    echo
    say "Please read more about HD wallets at:"
    say "https://cardano-community.github.io/support-faq/#/wallets?id=heirarchical-deterministic-hd-wallets"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    waitForInput && continue

    ;; ###################################################################
    
    register)

    clear
    say " >> WALLET >> REGISTER" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo
    
    say "# Select wallet to register (only non-registered wallets shown)"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "non-reg" "${WALLET_PAY_SK_FILENAME}" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_SK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    else
      if ! selectWallet "non-reg" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    fi
    echo
    
    getBaseAddress ${wallet_name}
    getBalance ${base_addr}

    if [[ ${lovelace} -gt 0 ]]; then
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Funds in wallet:"  "$(formatLovelace ${lovelace})")" "log"
        echo
      fi
    else
      say "${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
      keyDeposit=$(jq -r '.keyDeposit' "${TMP_FOLDER}"/protparams.json)
      say "Funds for key deposit($(formatLovelace ${keyDeposit}) ADA) + transaction fee needed to register the wallet"
      waitForInput && continue
    fi
    
    if ! registerStakeWallet ${wallet_name} "true"; then
      waitForInput && continue
    fi

    echo && say "${FG_GREEN}${wallet_name}${NC} successfully registered on chain!" "log"
    
    waitForInput && continue

    ;; ###################################################################
    
    deregister)

    clear
    say " >> WALLET >> DE-REGISTER" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo
    
    say "# Select wallet to de-register (only registered wallets shown)"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "delegate" "${WALLET_PAY_SK_FILENAME}" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_SK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    else
      if ! selectWallet "delegate" "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    fi
    echo
    
    getRewards ${wallet_name}
    if [[ "${reward_lovelace}" -gt 0 ]]; then
      say "${FG_YELLOW}WARN${NC}: wallet has unclaimed rewards, please use 'Funds >> Withdraw Rewards' before de-registration to claim your rewards"
      waitForInput && continue
    fi

    getBaseAddress ${wallet_name}
    getBalance ${base_addr}
    
    if [[ ${lovelace} -le 0 ]]; then
      say "${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
      say "Funds for transaction fee needed to deregister the wallet"
      waitForInput && continue
    fi
    
    if ! deregisterStakeWallet ${wallet_name}; then
      [[ -f ${stake_dereg_file} ]] && rm -f ${stake_dereg_file}
      waitForInput && continue
    fi
    
    say "${FG_YELLOW}Waiting for wallet de-registration to be recorded on chain${NC}"
    while true; do
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${base_addr}
      if [[ ${lovelace} -ne ${newBalance} ]]; then
        say "${FG_YELLOW}WARN${NC}: Balance mismatch, wallet de-registration not included in latest block... waiting for next block!"
        say "$(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance})" 1
      else
        break
      fi
    done

    if [[ ${lovelace} -ne ${newBalance} ]]; then
      say "${FG_YELLOW}WARN${NC}: wallet de-registration check aborted"
      waitForInput && continue
    fi

    echo && say "${FG_GREEN}${wallet_name}${NC} successfully de-registered from chain!" "log"
    say "Key deposit fee that will be refunded : ${FG_CYAN}$(formatLovelace ${keyDeposit})${NC} ADA" "log"
    
    waitForInput && continue

    ;; ###################################################################

    list)

    clear
    say " >> WALLET >> LIST" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "${FG_CYAN}OFFLINE MODE${NC}: CNTools started in offline mode, wallet balance not shown!"
    fi
    
    [[ ! "$(ls -A "${WALLET_FOLDER}")" ]] && echo && say "${FG_YELLOW}No wallets available!${NC}" "log"

    while IFS= read -r -d '' wallet; do
      wallet_name=$(basename ${wallet})
      enc_files=$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c)
      if [[ ${CNTOOLS_MODE} = "CONNECTED" ]] && isWalletRegistered ${wallet_name}; then registered="yes"; else registered="no"; fi
      echo
      if [[ ${enc_files} -gt 0 && ${registered} = "yes" ]]; then
        say "${FG_GREEN}${wallet_name}${NC} - ${FG_CYAN}REGISTERED${NC} (${FG_YELLOW}encrypted${NC})" "log"
      elif [[ ${registered} = "yes" ]]; then
        say "${FG_GREEN}${wallet_name}${NC} - ${FG_CYAN}REGISTERED${NC}" "log"
      elif [[ ${enc_files} -gt 0 ]]; then
        say "${FG_GREEN}${wallet_name}${NC} (${FG_YELLOW}encrypted${NC})" "log"
      else
        say "${FG_GREEN}${wallet_name}${NC}" "log"
      fi
      getBaseAddress ${wallet_name}
      getPayAddress ${wallet_name}
      if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
        [[ -n ${base_addr} ]] && say "$(printf "%-15s : %s" "Address"  "${base_addr}")" "log"
        [[ -n ${pay_addr} ]] && say "$(printf "%-15s : %s" "Enterprise Addr"  "${pay_addr}")" "log"
      else
        if [[ -n ${base_addr} ]]; then
          getBalance ${base_addr}
          say "$(printf "%-16s : %s" "Address"  "${base_addr}")" "log"
          say "$(printf "%-16s : ${FG_CYAN}%s${NC} ADA" "Funds"  "$(formatLovelace ${lovelace})")" "log"
        fi
        if [[ -n ${pay_addr} ]]; then
          getBalance ${pay_addr}
          if [[ ${lovelace} -gt 0 ]]; then
            say "$(printf "%-16s : %s" "Enterprise Addr"  "${pay_addr}")" "log"
            say "$(printf "%-16s : ${FG_CYAN}%s${NC} ADA" "Enterprise Funds"  "$(formatLovelace ${lovelace})")" "log"
          fi
        fi
        if [[ -z ${base_addr} && -z ${pay_addr} ]]; then
          say "${FG_RED}Not a supporeted wallet${NC} - genesis address?"
          say "Use an external script to send funds to a CNTools compatible wallet"
          continue
        fi
        getRewards ${wallet_name}
        if [[ "${reward_lovelace}" -ge 0 ]]; then
          say "$(printf "%-16s : ${FG_CYAN}%s${NC} ADA" "Rewards" "$(formatLovelace ${reward_lovelace})")" "log"
          delegation_pool_id=$(jq -r '.delegation // empty' <<< "${stakeAddressInfo}")
          if [[ -n ${delegation_pool_id} ]]; then
            unset poolName
            while IFS= read -r -d '' pool; do
              getPoolID "$(basename ${pool})"
              if [[ "${pool_id_bech32}" = "${delegation_pool_id}" ]]; then
                poolName=$(basename ${pool}) && break
              fi
            done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
            say "${FG_RED}Delegated to${NC} ${FG_BLUE}${poolName}${NC} ${FG_RED}(${delegation_pool_id})${NC}" "log"
          fi
        fi
      fi
    done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    echo
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput && continue
    ;; ###################################################################

    show)

    clear
    say " >> WALLET >> SHOW" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "${FG_CYAN}OFFLINE MODE${NC}: CNTools started in offline mode, limited wallet info shown!"
    fi
    
    if ! selectWallet "none" "${WALLET_PAY_VK_FILENAME}" >/dev/null; then
      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
    fi
    
    enc_files=$(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c)

    if [[ ${enc_files} -gt 0 ]]; then
      say "Wallet: ${FG_GREEN}${wallet_name}${NC} (${FG_YELLOW}encrypted${NC})" "log"
    else
      say "Wallet: ${FG_GREEN}${wallet_name}${NC}" "log"
    fi

    getBaseAddress ${wallet_name}
    getPayAddress ${wallet_name}
    
    if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
      getBalance ${base_addr}
      base_lovelace=${lovelace}
      if [[ ${utx0_count} -gt 0 ]]; then
        echo
        say "${FG_BLUE}UTxOs${NC}"
        head -n 2 "${TMP_FOLDER}"/fullUtxo.out
        head -n 10 "${TMP_FOLDER}"/balance.out
        [[ ${utx0_count} -gt 10 ]] && say "... (top 10 UTx0 with most lovelace)"
      fi

      getBalance ${pay_addr}
      pay_lovelace=${lovelace}
      if [[ ${utx0_count} -gt 0 ]]; then
        echo
        say "${FG_BLUE}Enterprise UTxOs${NC}"
        head -n 2 "${TMP_FOLDER}"/fullUtxo.out
        head -n 10 "${TMP_FOLDER}"/balance.out
        [[ ${utx0_count} -gt 10 ]] && say "... (top 10 UTx0 with most lovelace)"
      fi
    fi

    echo
    if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
      if isWalletRegistered ${wallet_name}; then
        say "$(printf "%-19s : ${FG_GREEN}%s${NC}" "Registered" "YES")" "log"
      else
        say "$(printf "%-19s : ${FG_RED}%s${NC}" "Registered" "NO")" "log"
      fi
    else
      say "$(printf "%-19s : %s" "Registered" "Unknown")" "log"
    fi
    say "$(printf "%-19s : %s" "Address" "${base_addr}")" "log"
    if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
      say "$(printf "%-19s : ${FG_CYAN}%s${NC} ADA" "Funds" "$(formatLovelace ${base_lovelace})")" "log"
      getAddressInfo "${base_addr}"
      say "$(printf "%-19s : %s" "Era" "$(jq -r '.era' <<< ${address_info})")" "log"
      say "$(printf "%-19s : %s" "Encoding" "$(jq -r '.encoding' <<< ${address_info})")" "log"
    fi
    say "$(printf "%-19s : %s" "Enterprise Address" "${pay_addr}")" "log"
    if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
      say "$(printf "%-19s : ${FG_CYAN}%s${NC} ADA" "Enterprise Funds" "$(formatLovelace ${pay_lovelace})")" "log"
      getRewards ${wallet_name}
      if [[ "${reward_lovelace}" -ge 0 ]]; then
        say "$(printf "%-19s : ${FG_CYAN}%s${NC} ADA" "Rewards" "$(formatLovelace ${reward_lovelace})")" "log"
        say "$(printf "%-19s : ${FG_CYAN}%s${NC} ADA" "Funds + Rewards" "$(formatLovelace $((base_lovelace + reward_lovelace)))")" "log"
        delegation_pool_id=$(jq -r '.delegation  // empty' <<< "${stakeAddressInfo}")
        if [[ -n ${delegation_pool_id} ]]; then
          unset poolName
          while IFS= read -r -d '' pool; do
            getPoolID "$(basename ${pool})"
            if [[ "${pool_id_bech32}" = "${delegation_pool_id}" ]]; then
              poolName=$(basename ${pool}) && break
            fi
          done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
          echo
          say "${FG_RED}Delegated to${NC} ${FG_BLUE}${poolName}${NC} ${FG_RED}(${delegation_pool_id})${NC}" "log"
        fi
      fi
    fi
    echo
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput && continue

    ;; ###################################################################

    remove)

    clear
    say " >> WALLET >> REMOVE" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "${FG_CYAN}OFFLINE MODE${NC}: CNTools started in offline mode, unable to verify wallet balance"
    fi

    echo
    say "# Select wallet to remove"
    if ! selectWallet "none"; then # ${wallet_name} populated by selectWallet function
      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
    fi
    echo

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "Are you sure to delete wallet ${FG_GREEN}${wallet_name}${NC}?"
      select_opt "[y] Yes" "[n] No"
      case $? in
        0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
           ;;
        1) echo && say "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
           ;;
      esac
      waitForInput && continue
    fi

    if ! getBaseAddress ${wallet_name} && ! getPayAddress ${wallet_name}; then
      say "${FG_RED}WARN${NC}: unable to get address for wallet and do a balance check"
      say "\nAre you sure to delete wallet ${FG_GREEN}${wallet_name}${NC} anyway?"
      select_opt "[y] Yes" "[n] No"
      case $? in
        0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
           ;;
        1) echo && say "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
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
      say "INFO: This wallet appears to be empty"
      say "${FG_RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup\n"
      say "Are you sure to delete wallet ${FG_GREEN}${wallet_name}${NC}?"
      select_opt "[y] Yes" "[n] No"
      case $? in
        0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
           ;;
        1) echo && say "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
           ;;
      esac
    else
      say "${FG_RED}WARN${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not empty!"
      [[ ${base_lovelace} -gt 0 ]] && say "Funds : ${FG_CYAN}$(formatLovelace ${base_lovelace})${NC} ADA"
      [[ ${pay_lovelace} -gt 0 ]] && say "Enterprise Funds : ${FG_CYAN}$(formatLovelace ${base_lovelace})${NC} ADA"
      [[ ${reward_lovelace} -gt 0 ]] && say "Rewards : ${FG_CYAN}$(formatLovelace ${reward_lovelace})${NC} ADA"
      echo
      say "${FG_RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup\n"
      say "Are you sure to delete wallet ${FG_GREEN}${wallet_name}${NC}?"
      select_opt "[y] Yes" "[n] No"
      case $? in
        0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
           ;;
        1) echo && say "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
           ;;
      esac
    fi

    waitForInput && continue

    ;; ###################################################################

    decrypt)

    clear
    say " >> WALLET >> DECRYPT" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo

    say "# Select wallet to decrypt"
    if ! selectWallet "none"; then # ${wallet_name} populated by selectWallet function
      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
    fi

    filesUnlocked=0
    keysDecrypted=0

    echo
    say "# Removing write protection from all wallet files" "log"
    while IFS= read -r -d '' file; do
      if [[ ${ENABLE_CHATTR} = true && $(lsattr -R "$file") =~ -i- ]]; then
        sudo chattr -i "${file}"
      fi
      chmod 600 "${file}"
      filesUnlocked=$((++filesUnlocked))
      say "${file}"
    done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    echo
    say "# Decrypting GPG encrypted wallet files" "log"
    echo
    if ! getPassword; then # $password variable populated by getPassword function
      say "\n\n" && say "${FG_RED}ERROR${NC}: password input aborted!"
      waitForInput && continue
    fi
    while IFS= read -r -d '' file; do
      decryptFile "${file}" "${password}" && \
      chmod 600 "${file::-4}" && \
      keysDecrypted=$((++keysDecrypted))
    done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
    unset password

    echo
    say "Wallet unprotected: ${FG_GREEN}${wallet_name}${NC}" "log"
    say "Files unlocked:     ${filesUnlocked}" "log"
    say "Files decrypted:    ${keysDecrypted}" "log"
    if [[ ${filesUnlocked} -ne 0 || ${keysDecrypted} -ne 0 ]]; then
      echo
      say "${FG_YELLOW}Wallet files are now unprotected${NC}"
      say "Use 'WALLET >> ENCRYPT' to re-lock"
    fi
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput && continue

    ;; ###################################################################

    encrypt)

    clear
    say " >> WALLET >> ENCRYPT" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo

    say "# Select wallet to encrypt"
    if ! selectWallet "none"; then # ${wallet_name} populated by selectWallet function
      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
    fi

    filesLocked=0
    keysEncrypted=0

    echo
    say "# Encrypting sensitive wallet keys with GPG" "log"
    echo
    if ! getPassword confirm; then # $password variable populated by getPassword function
      say "\n\n" && say "${FG_RED}ERROR${NC}: password input aborted!"
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
    say "# Write protecting all wallet keys with 400 permission and if enabled 'chattr +i'" "log"
    while IFS= read -r -d '' file; do
      [[ ${file} = *.addr ]] && continue
      chmod 400 "${file}"
      if [[ ${ENABLE_CHATTR} = true && ! $(lsattr -R "$file") =~ -i- ]]; then
        sudo chattr +i "${file}"
      fi
      filesLocked=$((++filesLocked))
      say "${file}"
    done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    echo
    say "Wallet protected: ${FG_GREEN}${wallet_name}${NC}" "log"
    say "Files locked:     ${filesLocked}" "log"
    say "Files encrypted:  ${keysEncrypted}" "log"
    if [[ ${filesLocked} -ne 0 || ${keysEncrypted} -ne 0 ]]; then
      echo
      say "${FG_BLUE}Wallet files are now protected${NC}"
      say "Use 'WALLET >> DECRYPT' to unlock"
    fi
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput && continue

    ;; ###################################################################

  esac

  ;; ###################################################################

  funds)

  clear
  say " >> FUNDS" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  say " Handle Funds"
  echo
  say " ) Send      -  send ADA from a local wallet to an address or a wallet"
  say " ) Delegate  -  delegate stake wallet to a pool"
  say " ) Withdraw  -  withdraw earned rewards to base address"
  say " ) Metadata  -  post metadata on chain"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

  say " Select funds operation\n"
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
    say " >> FUNDS >> SEND" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo

    say "# Select ${FG_CYAN}source${NC} wallet"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "balance" "${WALLET_PAY_SK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    else
      if ! selectWallet "balance"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    fi
    s_wallet="${wallet_name}"
    echo

    getBaseAddress ${s_wallet}
    getPayAddress ${s_wallet}
    getBalance ${base_addr}
    base_lovelace=${lovelace}
    getBalance ${pay_addr}
    pay_lovelace=${lovelace}

    if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
      # Both payment and base address available with funds, let user choose what to use
      say "Select source wallet address"
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        say "$(printf "%s\t\t${FG_CYAN}%s${NC} ADA" "Funds :"  "$(formatLovelace ${base_lovelace})")" "log"
        say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")" "log"
      fi
      echo
      select_opt "[b] Base (default)" "[e] Enterprise" "[Esc] Cancel"
      case $? in
        0) s_addr="${base_addr}" ;;
        1) s_addr="${pay_addr}" ;;
        2) continue ;;
      esac
    elif [[ ${pay_lovelace} -gt 0 ]]; then
      s_addr="${pay_addr}"
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")" "log"
      fi
    elif [[ ${base_lovelace} -gt 0 ]]; then
      s_addr="${base_addr}"
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        say "$(printf "%s\t\t${FG_CYAN}%s${NC} ADA" "Funds :"  "$(formatLovelace ${base_lovelace})")" "log"
      fi
    else
      say "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${s_wallet}${NC}"
      waitForInput && continue
    fi

    s_payment_sk_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_PAY_SK_FILENAME}"

    # Amount
    echo
    say "# Amount to Send (in ADA)"
    echo
    say "Valid entry:  ${FG_CYAN}Integer${NC} (e.g. 15) or ${FG_CYAN}Decimal${NC} (e.g. 956.1235) - commas allowed as thousand separator"
    say "              The string '${FG_CYAN}all${NC}' to send all available funds in source wallet"
    echo
    say "Info:         If destination and source wallet is the same and amount set to 'all',"
    say "              wallet will be defraged, ie converts multiple UTxO's to one"
    echo
    read -r -p "Amount (ADA): " amountADA
    amountADA="${amountADA//,}"

    echo
    if  [[ "${amountADA}" != "all" ]]; then
      if ! ADAtoLovelace "${amountADA}" >/dev/null; then
        waitForInput && continue
      fi
      amountLovelace=$(ADAtoLovelace "${amountADA}")
      say "Fee payed by sender? [else amount sent is reduced]"
      select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
      case $? in
        0) include_fee="no" ;;
        1) include_fee="yes" ;;
        2) continue ;;
      esac
    else
      getBalance ${s_addr}
      amountLovelace=${lovelace}
      say "ADA to send set to total supply: $(formatLovelace ${amountLovelace})" "log"
      include_fee="yes"
    fi
    echo

    # Destination
    d_wallet=""
    say "# Select ${FG_CYAN}destination${NC} type"
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
           say "\n${FG_RED}ERROR${NC}: sending to same address as source not supported"
           waitForInput && continue
         else
           say "\n${FG_RED}ERROR${NC}: no address found for wallet ${FG_GREEN}${d_wallet}${NC} :("
           waitForInput && continue
         fi
         ;;
      1) echo && read -r -p "Address: " d_addr ;;
      2) continue ;;
    esac
    # Destination could be empty, if so without getting a valid address
    if [[ -z ${d_addr} ]]; then
      say "${FG_RED}ERROR${NC}: destination address field empty"
      waitForInput && continue
    fi

    if ! sendADA "${d_addr}" "${amountLovelace}" "${s_addr}" "${s_payment_sk_file}" "${include_fee}"; then
      waitForInput && continue
    fi

    say "\n${FG_YELLOW}Waiting for payment to be recorded on chain${NC}"
    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${s_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say "${FG_YELLOW}WARN${NC}: Balance mismatch, transaction not included in latest block... waiting for next block!"
      say "$(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance})" 1
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${s_addr}
    done

    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    s_balance=${lovelace}

    getBalance ${d_addr}

    d_balance=${lovelace}

    getPayAddress ${s_wallet}
    [[ "${pay_addr}" = "${s_addr}" ]] && s_wallet_type=" (Enterprise)" || s_wallet_type=""
    getPayAddress ${d_wallet}
    [[ "${pay_addr}" = "${d_addr}" ]] && d_wallet_type=" (Enterprise)" || d_wallet_type=""

    echo
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say "Transaction" "log"
    say "  From          : ${FG_GREEN}${s_wallet}${NC}${s_wallet_type}" "log"
    say "  Amount        : $(formatLovelace ${amountLovelace}) ADA" "log"
    if [[ -n "${d_wallet}" ]]; then
      say "  To            : ${FG_GREEN}${d_wallet}${NC}${d_wallet_type}" "log"
    else
      say "  To            : ${d_addr}" "log"
    fi
    say "  Fees          : $(formatLovelace ${minFee}) ADA" "log"
    say "  Balance" "log"
    say "  - Source      : $(formatLovelace ${s_balance}) ADA" "log"
    say "  - Destination : $(formatLovelace ${d_balance}) ADA" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput && continue

    ;; ###################################################################

    delegate)  # [WALLET NAME] [POOL NAME]

    clear
    say " >> FUNDS >> DELEGATE" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo

    say "# Select wallet to delegate"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "delegate" "${WALLET_PAY_SK_FILENAME}" "${WALLET_STAKE_SK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    else
      if ! selectWallet "delegate" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    fi
    echo

    getBaseAddress ${wallet_name}
    getBalance ${base_addr}
    if [[ ${lovelace} -gt 0 ]]; then
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Funds in wallet:"  "$(formatLovelace ${lovelace})")" "log"
      fi
    else
      say "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
      waitForInput && continue
    fi
    getRewards ${wallet_name}

    if [[ reward_lovelace -eq -1 ]]; then
      if [[ ${op_mode} = "online" ]]; then
        if ! registerStakeWallet ${wallet_name}; then waitForInput && continue; fi
      else
        say "The wallet is not a registered wallet on chain and CNTools run in hybrid mode"
        say "Please first register the wallet using 'Wallet >> Register'"
        waitForInput && continue
      fi
    fi

    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"

    echo
    say "Do you want to delegate to a local pool or specify the pools cold vkey cbor-hex?"
    select_opt "[p] Pool" "[v] Vkey" "[Esc] Cancel"
    case $? in
      0) if ! selectPool "reg" "${POOL_COLDKEY_VK_FILENAME}"; then # ${pool_name} populated by selectPool function
           waitForInput && continue
         fi
         pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
         ;;
      1) read -r -p "vkey cbor-hex(blank to cancel): " vkey_cbor
         [[ -z "${vkey_cbor}" ]] && continue
         pool_name="${vkey_cbor}"
         pool_coldkey_vk_file="${TMP_FOLDER}"/pool_delegation.vkey
         printf "{\"type\":\"StakePoolVerificationKey_ed25519\",\"description\":\"Stake Pool Operator Verification Key\",\"cborHex\":\"%s\"}" ${vkey_cbor} > "${pool_coldkey_vk_file}"
         ;;
      2) continue ;;
    esac

    #Generated Files
    delegation_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DELEGCERT_FILENAME}"

    say "" 1
    say "creating delegation cert" 1 "log"
    say "$ ${CCLI} stake-address delegation-certificate --stake-verification-key-file ${stake_vk_file} --cold-verification-key-file ${pool_coldkey_vk_file} --out-file ${delegation_cert_file}" 2
    ${CCLI} stake-address delegation-certificate --stake-verification-key-file "${stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${delegation_cert_file}"

    if ! delegate "${stake_sk_file}" "${payment_sk_file}" "${base_addr}" "${pool_coldkey_vk_file}" "${delegation_cert_file}" ; then
      if [[ ${op_mode} = "online" ]]; then
        echo && say "${FG_RED}ERROR${NC}: failure during delegation, removing newly created delegation certificate file"
        rm -f "${delegation_cert_file}"
      fi
      waitForInput && continue
    fi

    say "\n${FG_YELLOW}Waiting for wallet delegation to be recorded on chain${NC}"
    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${base_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say "${FG_YELLOW}WARN${NC}: Balance mismatch, transaction not included in latest block... waiting for next block!"
      say "$(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance})" 1
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${base_addr}
    done

    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    echo
    say "Delegation successfully registered" "log"
    say "Wallet : ${FG_GREEN}${wallet_name}${NC}" "log"
    say "Pool   : ${FG_GREEN}${pool_name}${NC}" "log"
    say "Amount : $(formatLovelace ${lovelace}) ADA" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput && continue

    ;; ###################################################################

    withdrawrewards)

    clear
    say " >> FUNDS >> WITHDRAW REWARDS" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo

    say "# Select wallet to withdraw funds from"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "reward" "${WALLET_PAY_SK_FILENAME}" "${WALLET_STAKE_SK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    else
      if ! selectWallet "reward"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    fi
    echo

    getBaseAddress ${wallet_name}
    stake_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_ADDR_FILENAME}"
    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"

    getBalance ${base_addr}
    getRewards ${wallet_name}

    if [[ ${reward_lovelace} -le 0 ]]; then
      say "Failed to locate any rewards associated with the chosen wallet, please try another one"
      waitForInput && continue
    elif [[ ${lovelace} -eq 0 ]]; then
      say "${FG_YELLOW}WARN${NC}: No funds in base address, please send funds to base address of wallet to cover withdraw transaction fee"
      waitForInput && continue
    fi

    say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Funds"  "$(formatLovelace ${lovelace})")" "log"
    say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Rewards"  "$(formatLovelace ${reward_lovelace})")" "log"

    if ! withdrawRewards "${stake_sk_file}" "${payment_sk_file}" "${base_addr}" "${reward_addr}" ${reward_lovelace}; then
      waitForInput && continue
    fi

    say "\n${FG_YELLOW}Waiting for reward withdrawal to be recorded on chain${NC}"
    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${base_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say "${FG_YELLOW}WARN${NC}: Balance mismatch, transaction not included in latest block... waiting for next block!"
      say "$(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance})" 1
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${base_addr}
    done

    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    getRewards ${wallet_name}

    echo
    say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Funds"  "$(formatLovelace ${lovelace})")" "log"
    say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Rewards"  "$(formatLovelace ${reward_lovelace})")" "log"

    waitForInput && continue

    ;; ###################################################################

  esac

  ;; ###################################################################

  pool)

  clear
  say " >> POOL" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  say " Pool Management"
  echo
  say " ) New        -  create a new pool"
  say " ) Register   -  register created pool on chain using a stake wallet (pledge wallet)"
  say " ) Modify     -  change pool parameters and register updated pool values on chain"
  say " ) Retire     -  de-register stake pool from chain in specified epoch"
  say " ) List       -  a compact list view of available local pools"
  say " ) Show       -  detailed view of specified pool"
  say " ) Rotate     -  rotate pool KES keys"
  say " ) Decrypt    -  remove write protection and decrypt pool"
  say " ) Encrypt    -  encrypt pool cold keys and make all files immutable"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

  say " Select Pool operation\n"
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
    say " >> POOL >> NEW" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    read -r -p "Pool Name: " pool_name
    # Remove unwanted characters from pool name
    pool_name=${pool_name//[^[:alnum:]]/_}
    if [[ -z "${pool_name}" ]]; then
      say "${FG_RED}ERROR${NC}: Empty pool name, please retry!"
      waitForInput && continue
    fi
    echo
    mkdir -p "${POOL_FOLDER}/${pool_name}"

    pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
    pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
    pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"
    pool_vrf_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_SK_FILENAME}"

    if [[ -f "${pool_hotkey_vk_file}" ]]; then
      say "${FG_RED}WARN${NC}: A pool ${FG_GREEN}$pool_name${NC} already exists"
      say "      Choose another name or delete the existing one"
      waitForInput && continue
    fi

    ${CCLI} node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}"
    if [ -f "${POOL_FOLDER}-pregen/${pool_name}/${POOL_ID_FILENAME}" ]; then
      mv ${POOL_FOLDER}'-pregen/'${pool_name}/* ${POOL_FOLDER}/${pool_name}/
      rm -r ${POOL_FOLDER}'-pregen/'${pool_name}
    else
      ${CCLI} node key-gen --cold-verification-key-file "${pool_coldkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}"
    fi
    ${CCLI} node key-gen-VRF --verification-key-file "${pool_vrf_vk_file}" --signing-key-file "${pool_vrf_sk_file}"
    chmod 700 ${POOL_FOLDER}/${pool_name}/*
    getPoolID ${pool_name}

    say "Pool: ${FG_GREEN}${pool_name}${NC}" "log"
    [[ -n ${pool_id} ]] && say "ID (hex)    : ${pool_id}" "log"
    [[ -n ${pool_id_bech32} ]] && say "ID (bech32) : ${pool_id_bech32}" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput && continue

    ;; ###################################################################

    register)

    clear
    say " >> POOL >> REGISTER" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo

    say "# Select pool to register" "log"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectPool "non-reg" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_COLDKEY_SK_FILENAME}" "${POOL_VRF_VK_FILENAME}"; then # ${pool_name} populated by selectPool function
        waitForInput && continue
      fi
    else
      if ! selectPool "non-reg" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_VRF_VK_FILENAME}"; then # ${pool_name} populated by selectPool function
        waitForInput && continue
      fi
    fi
    echo

    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"

    say "# Pool Parameters"
    say "press enter to use default value\n"

    pledge_ada=50000 # default pledge
    [[ -f "${pool_config}" ]] && pledge_ada=$(jq -r '.pledgeADA //0' "${pool_config}")
    read -r -p "Pledge (in ADA, default: $(formatAda ${pledge_ada})): " pledge_enter
    pledge_enter="${pledge_enter//,}"
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
    [[ -f "${pool_config}" ]] && margin=$(jq -r '.margin //0' "${pool_config}")
    read -r -p "Margin (in %, default: ${margin}): " margin_enter
    if [[ -n "${margin_enter}" ]]; then
      if ! pctToFraction "${margin_enter}" >/dev/null; then
        waitForInput && continue
      fi
      margin_fraction=$(pctToFraction "${margin_enter}")
      margin="${margin_enter}"
    else
      margin_fraction=$(pctToFraction "${margin}")
    fi

    minPoolCost=$(( $(jq -r '.minPoolCost //0' "${TMP_FOLDER}"/protparams.json) / 1000000 )) # convert to ADA
    [[ ${minPoolCost} -gt 0 ]] && cost_ada=${minPoolCost} || cost_ada=400 # default cost
    if [[ -f "${pool_config}" ]]; then
      cost_ada_saved=$(jq -r '.costADA //0' "${pool_config}")
      [[ ${cost_ada_saved} -gt ${minPoolCost} ]] && cost_ada=${cost_ada_saved}
    fi
    read -r -p "Cost (in ADA, minimum: ${minPoolCost}, default: $(formatAda ${cost_ada})): " cost_enter
    cost_enter="${cost_enter//,}"
    if [[ -n "${cost_enter}" ]]; then
      if ! ADAtoLovelace "${cost_enter}" >/dev/null; then
        waitForInput && continue
      fi
      cost_lovelace=$(ADAtoLovelace "${cost_enter}")
      cost_ada="${cost_enter}"
    else
      cost_lovelace=$(ADAtoLovelace "${cost_ada}")
    fi
    if [[ ${cost_ada} -lt ${minPoolCost} ]]; then
      say "\n${FG_RED}ERROR${NC}: cost set lower than allowed"
      waitForInput && continue
    fi

    say "\n# Pool Metadata\n"
    meta_name="${pool_name}" # default name
    meta_ticker="${pool_name}" # default ticker
    meta_description="No Description" #default Description
    meta_homepage="https://foo.com" #default homepage
    meta_extended="https://foo.com/metadata/extended.json" #default extended
    meta_json_url="https://foo.bat/poolmeta.json" #default JSON
    pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta.json"
    if [[ -f "${pool_config}" ]]; then
      [[ "$(jq -r .json_url ${pool_config})" ]] && meta_json_url=$(jq -r .json_url "${pool_config}")
    fi

    read -r -p "Enter Pool's JSON URL to host metadata file - URL length should be less than 64 chars (default: ${meta_json_url}): " json_url_enter
    [[ -n "${json_url_enter}" ]] && meta_json_url="${json_url_enter}"
    if [[ ! "${meta_json_url}" =~ https?://.* || ${#meta_json_url} -gt 64 ]]; then
      say "${FG_RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
      waitForInput && continue
    fi

    metadata_done=false
    meta_tmp="${TMP_FOLDER}/url_poolmeta.json"
    if curl -sL -m ${CURL_TIMEOUT} -o "${meta_tmp}" ${meta_json_url} && jq -er . "${meta_tmp}" &>/dev/null; then
      [[ $(wc -c <"${meta_tmp}") -gt 512 ]] && say "${FG_RED}ERROR${NC}: file at specified URL contain more than allowed 512b of data!" && waitForInput && continue
      echo && jq -r . "${meta_tmp}" && echo
      if ! jq -er .name "${meta_tmp}" &>/dev/null; then say "${FG_RED}ERROR${NC}: unable to get 'name' field from downloaded metadata file!" && waitForInput && continue; fi
      if ! jq -er .ticker "${meta_tmp}" &>/dev/null; then say "${FG_RED}ERROR${NC}: unable to get 'ticker' field from downloaded metadata file!" && waitForInput && continue; fi
      if ! jq -er .homepage "${meta_tmp}" &>/dev/null; then say "${FG_RED}ERROR${NC}: unable to get 'homepage' field from downloaded metadata file!" && waitForInput && continue; fi
      if ! jq -er .description "${meta_tmp}" &>/dev/null; then say "${FG_RED}ERROR${NC}: unable to get 'description' field from downloaded metadata file!" && waitForInput && continue; fi
      say "Metadata exists at URL.  Use existing data?"
      select_opt "[y] Yes" "[n] No"
      case $? in
        0) mv "${meta_tmp}" "${POOL_FOLDER}/${pool_name}/poolmeta.json"
           metadata_done=true
           ;;
        1) rm "${meta_tmp}" ;; # clean up temp file
      esac
    fi
    if [[ ${metadata_done} = false ]]; then
      echo
      if [[ -f "${pool_meta_file}" ]]; then
        meta_name=$(jq -r .name "${pool_meta_file}")
        meta_ticker=$(jq -r .ticker "${pool_meta_file}")
        meta_homepage=$(jq -r .homepage "${pool_meta_file}")
        meta_description=$(jq -r .description "${pool_meta_file}")
        meta_extended=$(jq -r .extended "${pool_meta_file}")
      fi

      read -r -p "Enter Pool's Name (default: ${meta_name}): " name_enter
      [[ -n "${name_enter}" ]] && meta_name="${name_enter}"
      if [[ ${#meta_name} -gt 50 ]]; then
        say "${FG_RED}ERROR${NC}: Name cannot exceed 50 characters"
        waitForInput && continue
      fi
      read -r -p "Enter Pool's Ticker , should be between 3-5 characters (default: ${meta_ticker}): " ticker_enter
      ticker_enter=${ticker_enter//[^[:alnum:]]/_}
      [[ -n "${ticker_enter}" ]] && meta_ticker="${ticker_enter}"
      if [[ ${#meta_ticker} -lt 3 || ${#meta_ticker} -gt 5 ]]; then
        say "${FG_RED}ERROR${NC}: ticker must be between 3-5 characters"
        waitForInput && continue
      fi
      read -r -p "Enter Pool's Description (default: ${meta_description}): " desc_enter
      [[ -n "${desc_enter}" ]] && meta_description="${desc_enter}"
      if [[ ${#meta_description} -gt 255 ]]; then
        say "${FG_RED}ERROR${NC}: Description cannot exceed 255 characters"
        waitForInput && continue
      fi
      read -r -p "Enter Pool's Homepage (default: ${meta_homepage}): " homepage_enter
      [[ -n "${homepage_enter}" ]] && meta_homepage="${homepage_enter}"
      if [[ ! "${meta_homepage}" =~ https?://.* || ${#meta_homepage} -gt 64 ]]; then
        say "${FG_RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
        waitForInput && continue
      fi
      say "\nOptionally set an extended metadata URL?"
      select_opt "[n] No" "[y] Yes"
      case $? in
        0) meta_extended_option=""
           ;;
        1) echo && read -r -p "Enter URL to extended metadata (default: ${meta_extended}): " extended_enter
           extended_enter="${extended_enter}"
           [[ -n "${extended_enter}" ]] && meta_extended="${extended_enter}"
           if [[ ! "${meta_extended}" =~ https?://.* || ${#meta_extended} -gt 64 ]]; then
             say "${FG_RED}ERROR${NC}: invalid extended URL format or more than 64 chars in length"
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
        say "\n${FG_RED}ERROR${NC}: Total metadata size cannot exceed 512 chars in length, current length: ${metadata_size}"
        waitForInput && continue
      else
        cp -f "${new_pool_meta_file}" "${pool_meta_file}"
      fi

      say "\n${FG_YELLOW}Please host file ${pool_meta_file} as-is at ${meta_json_url}${NC}"
      waitForInput "Press any key to proceed with registration after metadata file is uploaded"
    fi

    relay_output=""
    relay_array=()
    say "\n# Pool Relay Registration"
    # ToDo SRV & IPv6 support
    if [[ -f "${pool_config}" && $(jq '.relays | length' "${pool_config}") -gt 0 ]]; then
      say "\nPrevious relay configuration:\n"
      jq -r '["TYPE","ADDRESS","PORT"], (.relays[] | [.type //"-",.address //"-",.port //"-"]) | @tsv' "${pool_config}" | column -t
      say "\nReuse previous configuration?"
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
          0) read -r -p "Enter relays's DNS record, only A or AAAA DNS records: " relay_dns_enter
             if [[ -z "${relay_dns_enter}" ]]; then
               say "${FG_RED}ERROR${NC}: DNS record can not be empty!"
             else
               read -r -p "Enter relays's port: " relay_port_enter
               if [[ -n "${relay_port_enter}" ]]; then
                 if [[ ! "${relay_port_enter}" =~ ^[0-9]+$ || "${relay_port_enter}" -lt 1 || "${relay_port_enter}" -gt 65535 ]]; then
                   say "${FG_RED}ERROR${NC}: invalid port number!"
                 else
                   relay_array+=( "type" "DNS_A" "address" "${relay_dns_enter}" "port" "${relay_port_enter}" )
                   relay_output+="--single-host-pool-relay ${relay_dns_enter} --pool-relay-port ${relay_port_enter} "
                 fi
               else
                 say "${FG_RED}ERROR${NC}: Port can not be empty!"
               fi
             fi
             ;;
          1) read -r -p "Enter relays's IPv4 address: " relay_ipv4_enter
             if [[ -n "${relay_ipv4_enter}" ]]; then
               if ! validIP "${relay_ipv4_enter}"; then
                 say "${FG_RED}ERROR${NC}: invalid IPv4 address format!"
               else
                 read -r -p "Enter relays's port: " relay_port_enter
                 if [[ -n "${relay_port_enter}" ]]; then
                   if [[ ! "${relay_port_enter}" =~ ^[0-9]+$ || "${relay_port_enter}" -lt 1 || "${relay_port_enter}" -gt 65535 ]]; then
                     say "${FG_RED}ERROR${NC}: invalid port number!"
                   else
                     relay_array+=( "type" "IPv4" "address" "${relay_ipv4_enter}" "port" "${relay_port_enter}" )
                     relay_output+="--pool-relay-port ${relay_port_enter} --pool-relay-ipv4 ${relay_ipv4_enter} "
                   fi
                 else
                   say "${FG_RED}ERROR${NC}: Port can not be empty!"
                 fi
               fi
             else
               say "${FG_RED}ERROR${NC}: IPv4 address can not be empty!"
             fi
             ;;
          2) continue 2 ;;
        esac
        say "Add more relay entries?"
        select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
        case $? in
          0) break ;;
          1) continue ;;
          2) continue 2 ;;
        esac
      done
    fi

    say "\n# Select ${FG_CYAN}owner/pledge${NC} wallet"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "delegate" "${WALLET_PAY_SK_FILENAME}" "${WALLET_STAKE_SK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    else
      if ! selectWallet "delegate" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    fi
    echo

    owner_wallet="${wallet_name}"
    getBaseAddress ${owner_wallet}
    getBalance ${base_addr}

    if [[ ${lovelace} -gt 0 ]]; then
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Funds in owner wallet:"  "$(formatLovelace ${lovelace})")" "log"
        echo
      fi
    else
      say "${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${owner_wallet}${NC}"
      waitForInput && continue
    fi
    if ! isWalletRegistered ${owner_wallet}; then
      if [[ ${op_mode} = "online" ]]; then
        if ! registerStakeWallet ${owner_wallet}; then waitForInput && continue; fi
        echo
      else
        say "Owner wallet not a registered wallet on chain and CNTools run in hybrid mode"
        say "Please first register all wallets to use in pool registration using 'Wallet >> Register'"
        waitForInput && continue
      fi
    fi

    say "Use a different wallet for rewards?"
    select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
    case $? in
      0) reward_wallet="${owner_wallet}" && echo ;;
      1) if ! selectWallet "none" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
           [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
         fi
         reward_wallet="${wallet_name}"
         if ! isWalletRegistered ${reward_wallet}; then
           if [[ ${op_mode} = "hybrid" ]]; then
             say "\nOwner wallet not a registered wallet on chain and CNTools run in hybrid mode"
             say "Please first register all wallets to use in pool registration using 'Wallet >> Register'"
             waitForInput && continue
           fi
           getBaseAddress ${reward_wallet}
           getBalance ${base_addr}
           if [[ ${lovelace} -gt 0 ]]; then
             say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Funds in reward wallet:"  "$(formatLovelace ${lovelace})")" "log"
             echo
           else
             say "${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${reward_wallet}${NC}, needed to pay for registration fee"
             waitForInput && continue
           fi
           if ! registerStakeWallet ${reward_wallet}; then
             waitForInput && continue
           fi
         fi
         ;;
      2) continue ;;
    esac
    echo

    multi_owner_output=""
    multi_owner_skeys=()
    say "Register a multi-owner pool using stake vkey/skey files?"
    select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
    case $? in
      0) : ;;
      1) say "Enter path to ${FG_CYAN}${WALLET_STAKE_VK_FILENAME}${NC} & ${FG_CYAN}${WALLET_STAKE_SK_FILENAME}${NC} files in this order!"
         waitForInput "Press any key to open the file explorer"
         owner_count=1
         while true; do
           ((owner_count++))
           fileDialog 0 "Enter path to ${WALLET_STAKE_VK_FILENAME} file" "${WALLET_FOLDER}/"
           say "Owner #${owner_count} : vkey = ${file}"
           stake_vk_file_enter=${file}
           if [[ ${op_mode} = "online" ]]; then
             fileDialog 0 "Enter path to stake skey file" "${stake_vk_file_enter%/*}/${WALLET_STAKE_SK_FILENAME}"
             say "Owner #${owner_count} : skey = ${file}"
             stake_sk_file_enter=${file}
             if [[ ! -f "${stake_vk_file_enter}" || ! -f "${stake_sk_file_enter}" ]]; then
               say "${FG_RED}ERROR${NC}: One or both files not found, please try again"
               ((owner_count--))
             else
               multi_owner_output+="--pool-owner-stake-verification-key-file ${stake_vk_file_enter} "
               multi_owner_skeys+=( "${stake_sk_file_enter}" )
             fi
           else
             if [[ ! -f "${stake_vk_file_enter}" ]]; then
               say "${FG_RED}ERROR${NC}: file not found, please try again"
               ((owner_count--))
             else
               multi_owner_output+="--pool-owner-stake-verification-key-file ${stake_vk_file_enter} "
             fi
           fi
           say "Add more owners?"
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

    # Construct relay json array
    relay_json=$({
      say '['
      printf '{"%s":"%s","%s":"%s","%s":"%s"},\n' "${relay_array[@]}" | sed '$s/,$//'
      say ']'
    } | jq -c .)
    # Save pool config
    echo "{\"pledgeWallet\":\"$owner_wallet\",\"rewardWallet\":\"$reward_wallet\",\"pledgeADA\":$pledge_ada,\"margin\":$margin,\"costADA\":$cost_ada,\"json_url\":\"$meta_json_url\",\"relays\": $relay_json}" > "${pool_config}"

    owner_stake_vk_file="${WALLET_FOLDER}/${owner_wallet}/${WALLET_STAKE_VK_FILENAME}"
    owner_delegation_cert_file="${WALLET_FOLDER}/${owner_wallet}/${WALLET_DELEGCERT_FILENAME}"
    reward_stake_vk_file="${WALLET_FOLDER}/${reward_wallet}/${WALLET_STAKE_VK_FILENAME}"
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

    say "\n# Register Stake Pool" 1 "log"

    if [[ ${op_mode} = "online" ]]; then
      getCurrentKESperiod
      echo "${current_kes_period}" > ${pool_saved_kes_start}
      say "creating operational certificate" 1 "log"
      ${CCLI} node issue-op-cert --kes-verification-key-file "${pool_hotkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" --kes-period "${current_kes_period}" --out-file "${pool_opcert_file}"
    else
      say "\n${FG_YELLOW}Pool operational certificate not generated in hybrid mode,\nplease use 'Pool >> Rotate' in offline mode to generate new hot keys, op cert and KES start period and transfer to online node!${NC}" "log"
      say "${FG_CYAN}${pool_hotkey_vk_file}${NC}" "log"
      say "${FG_CYAN}${pool_hotkey_sk_file}${NC}" "log"
      say "${FG_CYAN}${pool_opcert_file}${NC}" "log"
      say "${FG_CYAN}${pool_saved_kes_start}${NC}" "log"
      waitForInput "press any key to continue" && echo
    fi

    say "creating registration certificate" 1 "log"
    say "$ ${CCLI} stake-pool registration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --vrf-verification-key-file ${pool_vrf_vk_file} --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file ${reward_stake_vk_file} --pool-owner-stake-verification-key-file ${owner_stake_vk_file} ${multi_owner_output} --out-file ${pool_regcert_file} ${NETWORK_IDENTIFIER} --metadata-url ${meta_json_url} --metadata-hash \$\(${CCLI} stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} \) ${relay_output}" 2
    say "" 2
    ${CCLI} stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${reward_stake_vk_file}" --pool-owner-stake-verification-key-file "${owner_stake_vk_file}" ${multi_owner_output} --out-file "${pool_regcert_file}" ${NETWORK_IDENTIFIER} --metadata-url "${meta_json_url}" --metadata-hash "$(${CCLI} stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} )" ${relay_output}

    say "creating delegation certificate for owner wallet" 1 "log"
    say "$ ${CCLI} stake-address delegation-certificate --stake-verification-key-file ${owner_stake_vk_file} --cold-verification-key-file ${pool_coldkey_vk_file} --out-file ${owner_delegation_cert_file}" 2
    say "" 2
    ${CCLI} stake-address delegation-certificate --stake-verification-key-file "${owner_stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${owner_delegation_cert_file}"

    delegate_reward_wallet="false"
    if [[ ! "${owner_wallet}" = "${reward_wallet}" ]]; then
      say "\nRe-stake reward wallet to pool?"
      select_opt "[y] Yes" "[n] No"
      case $? in
        0) delegate_reward_wallet="true"
           say "" 1
           say "creating delegation certificate for reward wallet" 1 "log"
           say "$ ${CCLI} stake-address delegation-certificate --stake-verification-key-file ${reward_stake_vk_file} --cold-verification-key-file ${pool_coldkey_vk_file} --out-file ${reward_delegation_cert_file}" 2
           ${CCLI} stake-address delegation-certificate --stake-verification-key-file "${reward_stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${reward_delegation_cert_file}"
           ;;
        1) : ;;
      esac
    fi

    say "sending transaction to chain" 1 "log"
    echo
    if ! registerPool "${pool_name}" "${reward_wallet}" "${delegate_reward_wallet}" "${owner_wallet}" "${multi_owner_skeys[@]}"; then
      if [[ $? -eq 1 ]]; then
        echo && say "${FG_RED}ERROR${NC}: failure during pool registration, removing newly created pledge and registration files"
        rm -f "${pool_regcert_file}" "${owner_delegation_cert_file}"
        [[ "${delegate_reward_wallet}" = "true" ]] && rm -f "${reward_delegation_cert_file}"
        waitForInput && continue
      fi
    fi
    chmod 700 ${POOL_FOLDER}/${pool_name}/*

    [[ -f "${pool_deregcert_file}" ]] && rm -f ${pool_deregcert_file} # delete de-registration cert if available

    if [[ ${op_mode} = "online" ]]; then
      say "\n${FG_YELLOW}Waiting for pool registration to be recorded on chain${NC}"
      if ! waitNewBlockCreated; then
        waitForInput && continue
      fi

      getBaseAddress ${owner_wallet}
      getBalance ${base_addr}

      while [[ ${lovelace} -ne ${newBalance} ]]; do
        say "${FG_YELLOW}WARN${NC}: Balance mismatch, transaction not included in latest block... waiting for next block!"
        say "$(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance})" 1
        if ! waitNewBlockCreated; then
          break
        fi
        getBalance ${base_addr}
      done

      if [[ ${lovelace} -ne ${newBalance} ]]; then
        waitForInput && continue
      fi

      echo
      say "Pool ${FG_GREEN}${pool_name}${NC} successfully registered!" "log"
    else
      echo
      say "Pool ${FG_GREEN}${pool_name}${NC} built!" "log"
      say "${FG_YELLOW}Follow the steps above to sign and submit transaction to complete the pool registration!${NC}" "log"
      echo
    fi
    say "Owner  : ${FG_GREEN}${owner_wallet}${NC}" "log"
    [[ ${multi_owner_count} -gt 0 ]] && say "         ${FG_BLUE}${multi_owner_count}${NC} extra owner(s) using stake keys" "log"
    say "Reward : ${FG_GREEN}${reward_wallet}${NC}" "log"
    say "Pledge : $(formatAda ${pledge_ada}) ADA" "log"
    say "Margin : ${margin}%" "log"
    say "Cost   : $(formatAda ${cost_ada}) ADA" "log"
    echo
    say "Uncomment and set value for POOL_NAME in $CNODE_HOME/scripts/env with '${pool_name}'" "log"
    if [[ ${op_mode} = "online" && ${lovelace} -lt ${pledge_lovelace} ]]; then
      echo
      say "${FG_YELLOW}WARN${NC}: Balance in pledge wallet is less than set pool pledge"
      say "      make sure to put enough funds in wallet to honor pledge"
    fi
    if [[ ${multi_owner_count} -gt 0 ]]; then
      echo
      say "${FG_BLUE}INFO${NC}: All multi-owner wallets added by keys need to be manually delegated to pool if not done already!"
    fi
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput && continue

    ;; ###################################################################

    modify)

    clear
    say " >> POOL >> MODIFY" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo

    say "# Select pool to modify"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectPool "reg" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_COLDKEY_SK_FILENAME}" "${POOL_VRF_VK_FILENAME}"; then # ${pool_name} populated by selectPool function
        waitForInput && continue
      fi
    else
      if ! selectPool "reg" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_VRF_VK_FILENAME}"; then # ${pool_name} populated by selectPool function
        waitForInput && continue
      fi
    fi
    echo

    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"

    if [[ ! -f ${pool_config} ]]; then
      say "${FG_YELLOW}WARN${NC}: Missing pool config file: ${pool_config}"
      say "Unable to show old values, please re-enter all values to generate a new pool config file"
      waitForInput "press any key to continue" && echo
    fi

    say "# Pool Parameters"
    say "press enter to use old value\n"

    [[ -f ${pool_config} ]] && pledge_ada=$(jq -r '.pledgeADA //0' "${pool_config}") || pledge_ada=0
    read -r -p "New Pledge (in ADA, old: $(formatAda ${pledge_ada})): " pledge_enter
    pledge_enter="${pledge_enter//,}"
    if [[ -n "${pledge_enter}" ]]; then
      if ! ADAtoLovelace "${pledge_enter}" >/dev/null; then
        waitForInput && continue
      fi
      pledge_lovelace=$(ADAtoLovelace "${pledge_enter}")
      pledge_ada="${pledge_enter}"
    else
      pledge_lovelace=$(ADAtoLovelace "${pledge_ada}")
    fi

    [[ -f ${pool_config} ]] && margin=$(jq -r '.margin //0' "${pool_config}") || margin=0
    read -r -p "New Margin (in %, old: ${margin}): " margin_enter
    if [[ -n "${margin_enter}" ]]; then
      if ! pctToFraction "${margin_enter}" >/dev/null; then
        waitForInput && continue
      fi
      margin_fraction=$(pctToFraction "${margin_enter}")
      margin="${margin_enter}"
    else
      margin_fraction=$(pctToFraction "${margin}")
    fi

    minPoolCost=$(( $(jq -r '.minPoolCost //0' "${TMP_FOLDER}"/protparams.json) / 1000000 )) # convert to ADA
    [[ -f ${pool_config} ]] && cost_ada=$(jq -r '.costADA //0' "${pool_config}") || cost_ada=0
    read -r -p "New Cost (in ADA, minimum: ${minPoolCost}, old: $(formatAda ${cost_ada})): " cost_enter
    cost_enter="${cost_enter//,}"
    if [[ -n "${cost_enter}" ]]; then
      if ! ADAtoLovelace "${cost_enter}" >/dev/null; then
        waitForInput && continue
      fi
      cost_lovelace=$(ADAtoLovelace "${cost_enter}")
      cost_ada="${cost_enter}"
    else
      cost_lovelace=$(ADAtoLovelace "${cost_ada}")
    fi
    if [[ ${cost_ada} -lt ${minPoolCost} ]]; then
      say "\n${FG_RED}ERROR${NC}: cost set lower than allowed"
      waitForInput && continue
    fi

    say "\n# Pool Metadata\n"

    pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta.json"
    [[ -f ${pool_config} && "$(jq -r .json_url ${pool_config})" ]] && meta_json_url=$(jq -r .json_url "${pool_config}") || meta_json_url=""

    read -r -p "Enter Pool's JSON URL to host metadata file - URL length should be less than 64 chars (old: ${meta_json_url}): " json_url_enter
    [[ -n "${json_url_enter}" ]] && meta_json_url="${json_url_enter}"
    if [[ ! "${meta_json_url}" =~ https?://.* || ${#meta_json_url} -gt 64 ]]; then
      say "${FG_RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
      waitForInput && continue
    fi

    metadata_done=false
    meta_tmp="${TMP_FOLDER}/url_poolmeta.json"
    if curl -sL -m ${CURL_TIMEOUT} -o "${meta_tmp}" ${meta_json_url} && jq -er . "${meta_tmp}" &>/dev/null; then
      [[ $(wc -c <"${meta_tmp}") -gt 512 ]] && say "${FG_RED}ERROR${NC}: file at specified URL contain more than allowed 512b of data!" && waitForInput && continue
      echo && jq -r . "${meta_tmp}" && echo
      if ! jq -er .name "${meta_tmp}" &>/dev/null; then say "${FG_RED}ERROR${NC}: unable to get 'name' field from downloaded metadata file!" && waitForInput && continue; fi
      if ! jq -er .ticker "${meta_tmp}" &>/dev/null; then say "${FG_RED}ERROR${NC}: unable to get 'ticker' field from downloaded metadata file!" && waitForInput && continue; fi
      if ! jq -er .homepage "${meta_tmp}" &>/dev/null; then say "${FG_RED}ERROR${NC}: unable to get 'homepage' field from downloaded metadata file!" && waitForInput && continue; fi
      if ! jq -er .description "${meta_tmp}" &>/dev/null; then say "${FG_RED}ERROR${NC}: unable to get 'description' field from downloaded metadata file!" && waitForInput && continue; fi
      say "Metadata exists at URL.  Use existing data?"
      select_opt "[y] Yes" "[n] No"
      case $? in
        0) mv "${meta_tmp}" "${POOL_FOLDER}/${pool_name}/poolmeta.json"
           metadata_done=true
           ;;
        1) rm "${meta_tmp}" ;; # clean up temp file
      esac
    fi
    if [[ ${metadata_done} = false ]]; then
      echo
      # ToDo align with wallet and smash
      if [[ -f "${pool_meta_file}" ]]; then
        meta_name=$(jq -r .name "${pool_meta_file}")
        meta_ticker=$(jq -r .ticker "${pool_meta_file}")
        meta_homepage=$(jq -r .homepage "${pool_meta_file}")
        meta_description=$(jq -r .description "${pool_meta_file}")
        meta_extended=$(jq -r .extended "${pool_meta_file}")
      fi

      read -r -p "Enter Pool's Name (default: ${meta_name}): " name_enter
      [[ -n "${name_enter}" ]] && meta_name="${name_enter}"
      if [[ ${#meta_name} -gt 50 ]]; then
        say "${FG_RED}ERROR${NC}: Name cannot exceed 50 characters"
        waitForInput && continue
      fi
      read -r -p "Enter Pool's Ticker , should be between 3-5 characters (default: ${meta_ticker}): " ticker_enter
      ticker_enter=${ticker_enter//[^[:alnum:]]/_}
      [[ -n "${ticker_enter}" ]] && meta_ticker="${ticker_enter}"
      if [[ ${#meta_ticker} -lt 3 || ${#meta_ticker} -gt 5 ]]; then
        say "${FG_RED}ERROR${NC}: ticker must be between 3-5 characters"
        waitForInput && continue
      fi
      read -r -p "Enter Pool's Description (default: ${meta_description}): " desc_enter
      [[ -n "${desc_enter}" ]] && meta_description="${desc_enter}"
      if [[ ${#meta_description} -gt 255 ]]; then
        say "${FG_RED}ERROR${NC}: Description cannot exceed 255 characters"
        waitForInput && continue
      fi
      read -r -p "Enter Pool's Homepage (default: ${meta_homepage}): " homepage_enter
      [[ -n "${homepage_enter}" ]] && meta_homepage="${homepage_enter}"
      if [[ ! "${meta_homepage}" =~ https?://.* || ${#meta_homepage} -gt 64 ]]; then
        say "${FG_RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
        waitForInput && continue
      fi
      say "\nOptionally set an extended metadata URL?"
      select_opt "[n] No" "[y] Yes"
      case $? in
        0) meta_extended_option=""
           ;;
        1) echo && read -r -p "Enter URL to extended metadata (default: ${meta_extended}): " extended_enter
          extended_enter="${extended_enter}"
          if [[ -n "${extended_enter}" ]]; then
            meta_extended="${extended_enter}"
          fi
          if [[ ! "${meta_extended}" =~ https?://.* || ${#meta_extended} -gt 64 ]]; then
            say "${FG_RED}ERROR${NC}: invalid extended URL format or more than 64 chars in length"
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
        say "\n${FG_RED}ERROR${NC}: Total metadata size cannot exceed 512 chars in length, current length: ${metadata_size}"
        waitForInput && continue
      else
        cp -f "${new_pool_meta_file}" "${pool_meta_file}"
      fi

      say "\n${FG_YELLOW}Please host file ${pool_meta_file} as-is at ${meta_json_url}${NC}"
      waitForInput "Press any key to proceed with re-registration after metadata file is uploaded"
    fi

    relay_output=""
    relay_array=()
    say "\n# Pool Relay Registration"
    # ToDo SRV & IPv6 support
    if [[ -f ${pool_config} && $(jq '.relays | length' "${pool_config}") -gt 0 ]]; then
      say "\nPrevious relay configuration:\n"
      jq -r '["TYPE","ADDRESS","PORT"], (.relays[] | [.type //"-",.address //"-",.port //"-"]) | @tsv' "${pool_config}" | column -t
      say "\nReuse previous configuration?"
      select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
      case $? in
        0) while read -r type address port; do
             relay_array+=( "type" "${type}" "address" "${address}" "port" "${port}" )
             if [[ ${type} = "DNS_A" ]]; then
               relay_output+="--single-host-pool-relay ${address} --pool-relay-port ${port} "
             elif [[ ${type} = "IPv4" ]]; then
               relay_output+="--pool-relay-port ${port} --pool-relay-ipv4 ${address} "
             fi
           done < <(jq -r '.relays[] | "\(.type) \(.address) \(.port)"' "${pool_config}")
           ;;
        1) : ;; # Do nothing
        2) continue ;;
      esac
    fi
    if [[ -z ${relay_output} ]]; then
      while true; do
        select_opt "[d] A or AAAA DNS record (single)" "[4] IPv4 address (multiple)" "[Esc] Cancel"
        case $? in
          0) read -r -p "Enter relays's DNS record, only A or AAAA DNS records: " relay_dns_enter
             if [[ -z "${relay_dns_enter}" ]]; then
               say "${FG_RED}ERROR${NC}: DNS record can not be empty!"
             else
               read -r -p "Enter relays's port: " relay_port_enter
               if [[ -n "${relay_port_enter}" ]]; then
                 if [[ ! "${relay_port_enter}" =~ ^[0-9]+$ || "${relay_port_enter}" -lt 1 || "${relay_port_enter}" -gt 65535 ]]; then
                   say "${FG_RED}ERROR${NC}: invalid port number!"
                 else
                   relay_array+=( "type" "DNS_A" "address" "${relay_dns_enter}" "port" "${relay_port_enter}" )
                   relay_output+="--single-host-pool-relay ${relay_dns_enter} --pool-relay-port ${relay_port_enter} "
                 fi
               else
                 say "${FG_RED}ERROR${NC}: Port can not be empty!"
               fi
             fi
             ;;
          1) read -r -p "Enter relays's IPv4 address: " relay_ipv4_enter
             if [[ -n "${relay_ipv4_enter}" ]]; then
               if ! validIP "${relay_ipv4_enter}"; then
                 say "${FG_RED}ERROR${NC}: invalid IPv4 address format!"
               else
                 read -r -p "Enter relays's port: " relay_port_enter
                 if [[ -n "${relay_port_enter}" ]]; then
                   if [[ ! "${relay_port_enter}" =~ ^[0-9]+$ || "${relay_port_enter}" -lt 1 || "${relay_port_enter}" -gt 65535 ]]; then
                     say "${FG_RED}ERROR${NC}: invalid port number!"
                   else
                     relay_array+=( "type" "IPv4" "address" "${relay_ipv4_enter}" "port" "${relay_port_enter}" )
                     relay_output+="--pool-relay-port ${relay_port_enter} --pool-relay-ipv4 ${relay_ipv4_enter} "
                   fi
                 else
                   say "${FG_RED}ERROR${NC}: Port can not be empty!"
                 fi
               fi
             else
               say "${FG_RED}ERROR${NC}: IPv4 address can not be empty!"
             fi
             ;;
          2) continue 2 ;;
        esac
        say "Add more relay entries?"
        select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
        case $? in
          0) break ;;
          1) continue ;;
          2) continue 2 ;;
        esac
      done
    fi
    echo

    # Owner wallet, also used to pay for pool update fee
    if [[ -f ${pool_config} ]]; then
      say "Old owner wallet:  ${FG_GREEN}$(jq -r '.pledgeWallet //empty' "${pool_config}")${NC}"
      say "Old reward wallet: ${FG_GREEN}$(jq -r '.rewardWallet //empty' "${pool_config}")${NC}"
      echo
    fi
    say "${FG_YELLOW}If a new wallet is chosen for owner/reward, a manual delegation to the pool with new wallet is needed${NC}"
    echo

    say "# Select ${FG_CYAN}owner/pledge${NC} wallet"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "delegate" "${WALLET_PAY_SK_FILENAME}" "${WALLET_STAKE_SK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    else
      if ! selectWallet "delegate" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    fi
    echo

    owner_wallet="${wallet_name}"
    getBaseAddress ${owner_wallet}
    getBalance ${base_addr}

    if [[ ${lovelace} -gt 0 ]]; then
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Funds in base address + rewards for owner wallet:"  "$(formatLovelace $((lovelace + reward_lovelace)))")" "log"
        echo
      fi
    else
      say "${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${owner_wallet}${NC}"
      waitForInput && continue
    fi
    if ! isWalletRegistered ${owner_wallet}; then
      if [[ ${op_mode} = "online" ]]; then
        if ! registerStakeWallet ${owner_wallet}; then waitForInput && continue; fi
        echo
      else
        say "Owner wallet not a registered wallet on chain and CNTools run in hybrid mode"
        say "Please first register all wallets to use in pool registration using 'Wallet >> Register'"
        waitForInput && continue
      fi
    fi

    say "Use a different wallet for rewards?"
    select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
    case $? in
      0) reward_wallet="${owner_wallet}" && echo ;;
      1) if ! selectWallet "none" "${WALLET_STAKE_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
           [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
         fi
         reward_wallet="${wallet_name}"
         if ! isWalletRegistered ${reward_wallet}; then
           if [[ ${op_mode} = "hybrid" ]]; then
             say "\nOwner wallet not a registered wallet on chain and CNTools run in hybrid mode"
             say "Please first register all wallets to use in pool registration using 'Wallet >> Register'"
             waitForInput && continue
           fi
           getBaseAddress ${reward_wallet}
           getBalance ${base_addr}
           if [[ ${lovelace} -gt 0 ]]; then
             say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Funds in reward wallet:"  "$(formatLovelace ${lovelace})")" "log"
           else
             say "${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${reward_wallet}${NC}, needed to pay for registration fee"
             waitForInput && continue
           fi
           if ! registerStakeWallet ${reward_wallet}; then
             waitForInput && continue
           fi
         fi
         ;;
      2) continue ;;
    esac
    echo

    multi_owner_output=""
    multi_owner_skeys=()
    say "Register a multi-owner pool using stake vkey/skey files?"
    select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
    case $? in
      0) : ;;
      1) say "Enter path to ${FG_CYAN}${WALLET_STAKE_VK_FILENAME}${NC} & ${FG_CYAN}${WALLET_STAKE_SK_FILENAME}${NC} files in this order!"
         waitForInput "Press any key to open the file explorer"
         owner_count=1
         while true; do
           ((owner_count++))
           fileDialog 0 "Enter path to ${WALLET_STAKE_VK_FILENAME} file" "${WALLET_FOLDER}/"
           say "Owner #${owner_count} : vkey = ${file}"
           stake_vk_file_enter=${file}
           if [[ ${op_mode} = "online" ]]; then
             fileDialog 0 "Enter path to stake skey file" "${stake_vk_file_enter%/*}/${WALLET_STAKE_SK_FILENAME}"
             say "Owner #${owner_count} : skey = ${file}"
             stake_sk_file_enter=${file}
             if [[ ! -f "${stake_vk_file_enter}" || ! -f "${stake_sk_file_enter}" ]]; then
               say "${FG_RED}ERROR${NC}: One or both files not found, please try again"
               ((owner_count--))
             else
               multi_owner_output+="--pool-owner-stake-verification-key-file ${stake_vk_file_enter} "
               multi_owner_skeys+=( "${stake_sk_file_enter}" )
             fi
           else
             if [[ ! -f "${stake_vk_file_enter}" ]]; then
               say "${FG_RED}ERROR${NC}: file not found, please try again"
               ((owner_count--))
             else
               multi_owner_output+="--pool-owner-stake-verification-key-file ${stake_vk_file_enter} "
             fi
           fi
           say "Add more owners?"
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

    # Construct relay json array
    relay_json=$({
      say '['
      printf '{"%s":"%s","%s":"%s","%s":"%s"},\n' "${relay_array[@]}" | sed '$s/,$//'
      say ']'
    } | jq -c .)
    # Update pool config
    echo "{\"pledgeWallet\":\"$owner_wallet\",\"rewardWallet\":\"$reward_wallet\",\"pledgeADA\":$pledge_ada,\"margin\":$margin,\"costADA\":$cost_ada,\"json_url\":\"$meta_json_url\",\"relays\": $relay_json}" > "${pool_config}"

    owner_stake_vk_file="${WALLET_FOLDER}/${owner_wallet}/${WALLET_STAKE_VK_FILENAME}"
    reward_stake_vk_file="${WALLET_FOLDER}/${reward_wallet}/${WALLET_STAKE_VK_FILENAME}"

    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"

    #Generated Files
    pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"
    pool_deregcert_file="${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}"
    # Make a backup of current reg cert
    cp -f "${pool_regcert_file}" "${pool_regcert_file}.tmp"

    say "\n# Modify Stake Pool" 1 "log"
    
    say "creating registration certificate" 1 "log"
    say "$ ${CCLI} stake-pool registration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --vrf-verification-key-file ${pool_vrf_vk_file} --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file ${reward_stake_vk_file} --pool-owner-stake-verification-key-file ${owner_stake_vk_file} ${multi_owner_output} --metadata-url ${meta_json_url} --metadata-hash \$\(${CCLI} stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} \) ${relay_output} ${NETWORK_IDENTIFIER} --out-file ${pool_regcert_file}" 2
    say "" 2
    ${CCLI} stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${reward_stake_vk_file}" --pool-owner-stake-verification-key-file "${owner_stake_vk_file}" ${multi_owner_output} --metadata-url "${meta_json_url}" --metadata-hash "$(${CCLI} stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} )" ${relay_output} ${NETWORK_IDENTIFIER} --out-file "${pool_regcert_file}"

    say "sending transaction to chain" 1 "log"
    if ! modifyPool "${pool_name}" "${reward_wallet}" "${owner_wallet}" "${multi_owner_skeys[@]}"; then
      if [[ $? -eq 1 ]]; then
        echo && say "${FG_RED}ERROR${NC}: failure during pool update, removing newly created registration certificate"
        mv -f "${pool_regcert_file}.tmp" "${pool_regcert_file}" # restore reg cert backup
        waitForInput && continue
      fi
    else
      rm -f "${pool_regcert_file}.tmp" # remove backup of old reg cert
      [[ -f "${pool_deregcert_file}" ]] && rm -f ${pool_deregcert_file} # delete de-registration cert if available
    fi
    chmod 700 ${POOL_FOLDER}/${pool_name}/*

    if [[ ${op_mode} = "online" ]]; then
      say "\n${FG_YELLOW}Waiting for pool re-registration to be recorded on chain${NC}"
      if ! waitNewBlockCreated; then
        waitForInput && continue
      fi
      getBaseAddress ${owner_wallet}
      getBalance ${base_addr}
      while [[ ${lovelace} -ne ${newBalance} ]]; do
        say "${FG_YELLOW}WARN${NC}: Balance mismatch, transaction not included in latest block... waiting for next block!"
        say "$(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance})" 1
        if ! waitNewBlockCreated; then
          break
        fi
        getBalance ${base_addr}
      done
      if [[ ${lovelace} -ne ${newBalance} ]]; then
        waitForInput && continue
      fi
      echo
      say "Pool ${FG_GREEN}${pool_name}${NC} successfully updated with new parameters!" "log"
    else
      echo
      say "Pool ${FG_GREEN}${pool_name}${NC} built!" "log"
      say "${FG_YELLOW}Follow the steps above to sign and submit transaction to complete the pool update!${NC}" "log"
      echo
    fi
    say "Owner  : ${FG_GREEN}${owner_wallet}${NC}" "log"
    [[ ${multi_owner_count} -gt 0 ]] && say "         ${FG_BLUE}${multi_owner_count}${NC} extra owner(s) using stake keys" "log"
    say "Reward : ${FG_GREEN}${reward_wallet}${NC}" "log"
    say "Pledge : $(formatAda ${pledge_ada}) ADA" "log"
    say "Margin : ${margin}%" "log"
    say "Cost   : $(formatAda ${cost_ada}) ADA" "log"
    if [[ ${op_mode} = "online" && ${lovelace} -lt ${pledge_lovelace} ]]; then
      echo
      say "${FG_YELLOW}WARN${NC}: Balance in pledge wallet is less than set pool pledge"
      say "      make sure to put enough funds in wallet to honor pledge"
    fi
    if [[ ${multi_owner_count} -gt 0 ]]; then
      echo
      say "${FG_BLUE}INFO${NC}: All multi-owner wallets added by keys need to be manually delegated to pool if not done already!"
    fi
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput && continue

    ;; ###################################################################

    retire)

    clear
    say " >> POOL >> RETIRE" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
      waitForInput && continue
    else
      if ! selectOpMode; then continue; fi
    fi
    echo

    say "# Select pool to retire"
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

    say "Current epoch: ${FG_BLUE}${epoch}${NC}" "log"
    epoch_start=$((epoch + 1))
    epoch_end=$((epoch + eMax))
    say "earlist epoch to retire pool is ${FG_BLUE}${epoch_start}${NC} and latest ${FG_BLUE}${epoch_end}${NC}" "log"
    echo

    read -r -p "Enter epoch in which to retire pool (blank for ${epoch_start}): " epoch_enter
    [[ -z "${epoch_enter}" ]] && epoch_enter=${epoch_start}

    if [[ ${epoch_enter} -lt ${epoch_start} || ${epoch_enter} -gt ${epoch_end} ]]; then
      say "${FG_RED}ERROR${NC}: epoch invalid, valid range: ${epoch_start}-${epoch_end}"
      waitForInput && continue
    fi
    
    say "# Select wallet for pool de-registration transaction fee"
    if [[ ${op_mode} = "online" ]]; then
      if ! selectWallet "balance" "${WALLET_PAY_VK_FILENAME}" "${WALLET_PAY_SK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
    else
      if ! selectWallet "balance" "${WALLET_PAY_VK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
        [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
      fi
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
      say "# Select wallet address to use"
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        say "$(printf "%s\t\t${FG_CYAN}%s${NC} ADA" "Funds :"  "$(formatLovelace ${base_lovelace})")" "log"
        say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")" "log"
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
        say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")" "log"
      fi
    elif [[ ${base_lovelace} -gt 0 ]]; then
      addr="${base_addr}"
      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        say "$(printf "%s\t\t${FG_CYAN}%s${NC} ADA" "Funds :"  "$(formatLovelace ${base_lovelace})")" "log"
      fi
    else
      say "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
      waitForInput && continue
    fi

    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_deregcert_file="${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}"
    pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"

    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"

    say "" 1
    say "creating de-registration cert" 1 "log"
    say "$ ${CCLI} stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file}" 2
    ${CCLI} stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file}

    if ! deRegisterPool "${pool_coldkey_sk_file}" "${pool_deregcert_file}" "${addr}" "${payment_sk_file}"; then
      waitForInput && continue
    fi
    
    [[ -f "${pool_regcert_file}" ]] && rm -f ${pool_regcert_file} # delete registration cert

    say "\n${FG_YELLOW}Waiting for pool de-registration to be recorded on chain${NC}"
    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say "${FG_YELLOW}WARN${NC}: Balance mismatch, transaction not included in latest block... waiting for next block!"
      say "$(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance})" 1
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${addr}
    done

    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    echo
    say "Pool ${FG_GREEN}${pool_name}${NC} set to be retired in epoch ${FG_BLUE}${epoch_enter}${NC}" "log"

    waitForInput

    ;; ###################################################################

    list)

    clear
    say " >> POOL >> LIST" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    while IFS= read -r -d '' pool; do
      echo
      getPoolID "$(basename ${pool})"
      pool_regcert_file="${pool}/${POOL_REGCERT_FILENAME}"
      pool_deregcert_file="${pool}/${POOL_DEREGCERT_FILENAME}"
      [[ -f "${pool_regcert_file}" ]] && pool_registered="${FG_GREEN}YES${NC}" || pool_registered="${FG_RED}NO${NC}"
      say "${FG_GREEN}$(basename ${pool})${NC} "
      say "$(printf "%-21s : %s" "ID (hex)" "${pool_id}")" "log"
      [[ -n ${pool_id_bech32} ]] && say "$(printf "%-21s : %s" "ID (bech32)" "${pool_id_bech32}")" "log"
      if [[ -f "${pool_deregcert_file}" ]]; then
        say "$(printf "%-21s : %s" "Registered" "${FG_RED}DE-REGISTERED${NC} - check 'Pool >> Show' for ledger registration status")" "log"
      else
        say "$(printf "%-21s : %s" "Registered" "${pool_registered} - check 'Pool >> Show' for ledger registration status")" "log"
      fi
      if [[ -f "${pool}/${POOL_CURRENT_KES_START}" ]]; then
        kesExpiration "$(cat "${pool}/${POOL_CURRENT_KES_START}")"
        if [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
          if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
            say "$(printf "%-21s : %s - ${FG_RED}%s${NC} %s ago" "KES expiration date" "${expiration_date}" "EXPIRED!" "$(showTimeLeft ${expiration_time_sec_diff:1})")" "log"
          else
            say "$(printf "%-21s : %s - ${FG_RED}%s${NC} %s until expiration" "KES expiration date" "${expiration_date}" "ALERT!" "$(showTimeLeft ${expiration_time_sec_diff})")" "log"
          fi
        elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
          say "$(printf "%-21s : %s - ${FG_YELLOW}%s${NC} %s until expiration" "KES expiration date" "${expiration_date}" "WARNING!" "$(showTimeLeft ${expiration_time_sec_diff})")" "log"
        else
          say "$(printf "%-21s : %s" "KES expiration date" "${expiration_date}")" "log"
        fi
      fi
    done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    echo
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput

    ;; ###################################################################

    show)

    clear
    say " >> POOL >> SHOW" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "${FG_CYAN}OFFLINE MODE${NC}: CNTools started in offline mode, locally saved info shown!"
    fi

    if ! selectPool "all" "${POOL_ID_FILENAME}" >/dev/null; then # ${pool_name} populated by selectPool function
      waitForInput && continue
    fi

    if [[ ${CNTOOLS_MODE} = "CONNECTED" ]]; then
      tput sc && say "Dumping ledger-state from node, can take a while on larger networks...\n"
      if ! timeout -k 5 $TIMEOUT_LEDGER_STATE ${CCLI} query ledger-state ${ERA_IDENTIFIER} ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} --out-file "${TMP_FOLDER}"/ledger-state.json; then
        tput rc && tput ed
        say "${FG_RED}ERROR${NC}: ledger dump failed/timed out"
        say "increase timeout value in cntools.config"
        waitForInput && continue
      fi
      tput rc && tput ed
    fi

    getPoolID ${pool_name}
    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      [[ -f "${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}" ]] && pool_registered="YES" || pool_registered="NO"
      [[ -f "${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}" ]] && ledger_retiring="?" || ledger_retiring=""
    else
      tput sc && say "Parsing ledger-state, can take a while on larger networks...\n"
      ledger_pstate=$(jq -r '.nesEs.esLState._delegationState._pstate' "${TMP_FOLDER}"/ledger-state.json)
      ledger_pParams=$(jq -r '._pParams."'"${pool_id}"'" // empty' <<< ${ledger_pstate})
      ledger_fPParams=$(jq -r '._fPParams."'"${pool_id}"'" // empty' <<< ${ledger_pstate})
      ledger_retiring=$(jq -r '._retiring."'"${pool_id}"'" // empty' <<< ${ledger_pstate})
      [[ -z "${ledger_fPParams}" ]] && ledger_fPParams="${ledger_pParams}"
      [[ -n "${ledger_pParams}" ]] && pool_registered="YES" || pool_registered="NO"
      tput rc && tput ed
    fi
    echo
    say "$(printf "%-21s : ${FG_GREEN}%s${NC}" "Pool" "${pool_name}")" "log"
    say "$(printf "%-21s : %s" "ID (hex)" "${pool_id}")" "log"
    [[ -n ${pool_id_bech32} ]] && say "$(printf "%-21s : %s" "ID (bech32)" "${pool_id_bech32}")" "log"
    [[ "${pool_registered}" = "YES" ]] && pool_reg_color="${FG_GREEN}" || pool_reg_color="${FG_RED}"
    if [[ -z "${ledger_retiring}" ]]; then
      say "$(printf "%-21s : ${pool_reg_color}%s${NC}" "Registered" "${pool_registered}")" "log"
    else
      say "$(printf "%-21s : ${pool_reg_color}%s${NC} - ${FG_RED}Retired in epoch %s${NC}" "Registered" "${pool_registered}" "${ledger_retiring}")" "log"
    fi
    pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta.json"
    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
    if [[ ${CNTOOLS_MODE} = "OFFLINE" && -f "${pool_meta_file}" ]]; then
      say "Metadata" "log"
      say "$(printf "  %-19s : %s" "Name" "$(jq -r .name "${pool_meta_file}")")" "log"
      say "$(printf "  %-19s : %s" "Ticker" "$(jq -r .ticker "${pool_meta_file}")")" "log"
      say "$(printf "  %-19s : %s" "Homepage" "$(jq -r .homepage "${pool_meta_file}")")" "log"
      say "$(printf "  %-19s : %s" "Description" "$(jq -r .description "${pool_meta_file}")")" "log"
      [[ -f "${pool_config}" ]] && meta_url="$(jq -r .json_url "${pool_config}")" || meta_url="---"
      say "$(printf "  %-19s : %s" "URL" "${meta_url}")" "log"
      meta_hash="$(${CCLI} stake-pool metadata-hash --pool-metadata-file "${pool_meta_file}" )"
      say "$(printf "  %-19s : %s" "Hash" "${meta_hash}")" "log"
    else
      if [[ -f "${pool_config}" ]]; then
        meta_json_url=$(jq -r .json_url "${pool_config}")
      else
        meta_json_url=$(jq -r '.metadata.url //empty' <<< "${ledger_fPParams}")
      fi
      if [[ -n ${meta_json_url} ]] && curl -sL -m ${CURL_TIMEOUT} -o "${TMP_FOLDER}/url_poolmeta.json" ${meta_json_url}; then
        say "Metadata" "log"
        say "$(printf "  %-19s : %s" "Name" "$(jq -r .name "$TMP_FOLDER/url_poolmeta.json")")" "log"
        say "$(printf "  %-19s : %s" "Ticker" "$(jq -r .ticker "$TMP_FOLDER/url_poolmeta.json")")" "log"
        say "$(printf "  %-19s : %s" "Homepage" "$(jq -r .homepage "$TMP_FOLDER/url_poolmeta.json")")" "log"
        say "$(printf "  %-19s : %s" "Description" "$(jq -r .description "$TMP_FOLDER/url_poolmeta.json")")" "log"
        say "$(printf "  %-19s : %s" "URL" "${meta_json_url}")" "log"
        meta_hash_url="$(${CCLI} stake-pool metadata-hash --pool-metadata-file "$TMP_FOLDER/url_poolmeta.json" )"
        meta_hash_pParams=$(jq -r '.metadata.hash //empty' <<< "${ledger_pParams}")
        meta_hash_fPParams=$(jq -r '.metadata.hash //empty' <<< "${ledger_fPParams}")
        say "$(printf "  %-19s : %s" "Hash URL" "${meta_hash_url}")" "log"
        if [[ "${pool_registered}" = "YES" ]]; then
          if [[ "${meta_hash_pParams}" = "${meta_hash_fPParams}" ]]; then
            say "$(printf "  %-19s : %s" "Hash Ledger" "${meta_hash_pParams}")" "log"
          else
            say "$(printf "  %-13s (${FG_YELLOW}%s${NC}) : %s" "Hash Ledger" "old" "${meta_hash_pParams}")" "log"
            say "$(printf "  %-13s (${FG_YELLOW}%s${NC}) : %s" "Hash Ledger" "new" "${meta_hash_fPParams}")" "log"
          fi
        fi
      else
        say "$(printf "%-21s : %s" "Metadata" "download failed for ${meta_json_url}")" "log"
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
          say "$(printf "%-21s : %s ADA" "Pledge" "$(formatAda "${conf_pledge::-6}")")" "log"
          say "$(printf "%-21s : %s %%" "Margin" "${conf_margin}")" "log"
          say "$(printf "%-21s : %s ADA" "Cost" "$(formatAda "${conf_cost::-6}")")" "log"
          say "$(printf "%-21s : %s (%s)" "Owner Wallet" "${FG_GREEN}${conf_owner}${NC}" "primary only, use online mode for multi-owner")" "log"
          say "$(printf "%-21s : %s" "Reward Wallet" "${FG_GREEN}${conf_reward}${NC}")" "log"
          relay_title="Relay(s)"
          while read -r type address port; do
            if [[ ${type} != "DNS_A" && ${type} != "IPv4" ]]; then
              say "$(printf "%-21s : %s" "${relay_title}" "unknown type (only IPv4/DNS supported in CNTools)")" "log"
            else
              say "$(printf "%-21s : %s:%s" "${relay_title}" "${address}" "${port}")" "log"
            fi
            relay_title=""
          done < <(jq -r '.relays[] | "\(.type) \(.address) \(.port)"' "${pool_config}")
        fi
      else
        pParams_pledge=$(jq -r '.pledge //0' <<< "${ledger_pParams}")
        fPParams_pledge=$(jq -r '.pledge //0' <<< "${ledger_fPParams}")
        if [[ ${pParams_pledge} -eq ${fPParams_pledge} ]]; then
          say "$(printf "%-21s : %s ADA" "Pledge" "$(formatAda "${pParams_pledge::-6}")")" "log"
        else
          say "$(printf "%-15s (${FG_YELLOW}%s${NC}) : %s ADA" "Pledge" "new" "$(formatAda "${fPParams_pledge::-6}")" )" "log"
        fi
        pParams_margin=$(LC_NUMERIC=C printf "%.4f" "$(jq -r '.margin //0' <<< "${ledger_pParams}")")
        fPParams_margin=$(LC_NUMERIC=C printf "%.4f" "$(jq -r '.margin //0' <<< "${ledger_fPParams}")")
        if [[ "${pParams_margin}" = "${fPParams_margin}" ]]; then
          say "$(printf "%-21s : %s %%" "Margin" "$(fractionToPCT "${pParams_margin}")")" "log"
        else
          say "$(printf "%-15s (${FG_YELLOW}%s${NC}) : %s %%" "Margin" "new" "$(fractionToPCT "${fPParams_margin}")" )" "log"
        fi
        pParams_cost=$(jq -r '.cost //0' <<< "${ledger_pParams}")
        fPParams_cost=$(jq -r '.cost //0' <<< "${ledger_fPParams}")
        if [[ ${pParams_cost} -eq ${fPParams_cost} ]]; then
          say "$(printf "%-21s : %s ADA" "Cost" "$(formatAda "${pParams_cost::-6}")")" "log"
        else
          say "$(printf "%-15s (${FG_YELLOW}%s${NC}) : %s ADA" "Cost" "new" "$(formatAda "${fPParams_cost::-6}")" )" "log"
        fi
        if [[ ! $(jq -c '.relays[] //empty' <<< "${ledger_pParams}") = $(jq -c '.relays[] //empty' <<< "${ledger_fPParams}") ]]; then
          say "$(printf "%-23s ${FG_YELLOW}%s${NC}" "" "Relay(s) updated, showing latest registered")" "log"
        fi
        ledger_relays=$(jq -c '.relays[] //empty' <<< "${ledger_fPParams}")
        relay_title="Relay(s)"
        if [[ -n "${ledger_relays}" ]]; then
          while read -r relay; do
            relay_ipv4="$(jq -r '."single host address".IPv4 //empty' <<< ${relay})"
            relay_dns="$(jq -r '."single host name".dnsName //empty' <<< ${relay})"
            if [[ -n ${relay_ipv4} ]]; then
              relay_port="$(jq -r '."single host address".port //empty' <<< ${relay})"
              say "$(printf "%-21s : %s:%s" "${relay_title}" "${relay_ipv4}" "${relay_port}")" "log"
            elif [[ -n ${relay_dns} ]]; then
              relay_port="$(jq -r '."single host name".port //empty' <<< ${relay})"
              say "$(printf "%-21s : %s:%s" "${relay_title}" "${relay_dns}" "${relay_port}")" "log"
            else
              say "$(printf "%-21s : %s" "${relay_title}" "unknown type (only IPv4/DNS supported in CNTools)")" "log"
            fi
            relay_title=""
          done <<< "${ledger_relays}"
        fi
        # get owners
        if [[ ! $(jq -c -r '.owners[] // empty' <<< "${ledger_pParams}") = $(jq -c -r '.owners[] // empty' <<< "${ledger_fPParams}") ]]; then
          say "$(printf "%-23s ${FG_YELLOW}%s${NC}" "" "Owner(s) updated, showing latest registered")" "log"
        fi
        owner_title="Owner(s)"
        while read -r owner; do
          owner_wallet=$(grep -r ${owner} "${WALLET_FOLDER}" | head -1 | cut -d':' -f1)
          if [[ -n ${owner_wallet} ]]; then
            owner_wallet="$(basename "$(dirname "${owner_wallet}")")"
            say "$(printf "%-21s : %s" "${owner_title}" "${FG_GREEN}${owner_wallet}${NC}")" "log"
          else
            say "$(printf "%-21s : %s" "${owner_title}" "${owner}")" "log"
          fi
          owner_title=""
        done < <(jq -c -r '.owners[] // empty' <<< "${ledger_fPParams}")
        if [[ ! $(jq -r '.rewardAccount.credential."key hash" // empty' <<< "${ledger_pParams}") = $(jq -r '.rewardAccount.credential."key hash" // empty' <<< "${ledger_fPParams}") ]]; then
          say "$(printf "%-23s ${FG_YELLOW}%s${NC}" "" "Reward account updated, showing latest registered")" "log"
        fi
        reward_account=$(jq -r '.rewardAccount.credential."key hash" // empty' <<< "${ledger_fPParams}")
        if [[ -n ${reward_account} ]]; then
          reward_wallet=$(grep -r ${reward_account} "${WALLET_FOLDER}" | head -1 | cut -d':' -f1)
          if [[ -n ${reward_wallet} ]]; then
            reward_wallet="$(basename "$(dirname "${reward_wallet}")")"
            say "$(printf "%-21s : %s" "Reward wallet" "${FG_GREEN}${reward_wallet}${NC}")" "log"
          else
            say "$(printf "%-21s : %s" "Reward account" "${reward_account}")" "log"
          fi
        fi
        stake_pct=$(fractionToPCT "$(LC_NUMERIC=C printf "%.10f" "$(${CCLI} query stake-distribution ${ERA_IDENTIFIER} ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} | grep "${pool_id_bech32}" | tr -s ' ' | cut -d ' ' -f 2)")")
        if validateDecimalNbr ${stake_pct}; then
          say "$(printf "%-21s : %s %%" "Stake distribution" "${stake_pct}")" "log"
        fi
      fi
      if [[ -f "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}" ]]; then
        kesExpiration "$(cat "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}")"
        if [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
          if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
            say "$(printf "%-21s : %s - ${FG_RED}%s${NC} %s ago" "KES expiration date" "${expiration_date}" "EXPIRED!" "$(showTimeLeft ${expiration_time_sec_diff:1})")" "log"
          else
            say "$(printf "%-21s : %s - ${FG_RED}%s${NC} %s until expiration" "KES expiration date" "${expiration_date}" "ALERT!" "$(showTimeLeft ${expiration_time_sec_diff})")" "log"
          fi
        elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
          say "$(printf "%-21s : %s - ${FG_YELLOW}%s${NC} %s until expiration" "KES expiration date" "${expiration_date}" "WARNING!" "$(showTimeLeft ${expiration_time_sec_diff})")" "log"
        else
          say "$(printf "%-21s : %s" "KES expiration date" "${expiration_date}")" "log"
        fi
      fi
    fi
    echo
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput
    
    ;; ###################################################################

    rotate)

    clear
    say " >> POOL >> ROTATE KES" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    
    say "# Select pool to rotate KES keys on"
    if ! selectPool "all" "${POOL_COLDKEY_SK_FILENAME}" "${POOL_HOTKEY_SK_FILENAME}" "${POOL_HOTKEY_VK_FILENAME}" "${POOL_OPCERT_COUNTER_FILENAME}"; then # ${pool_name} populated by selectPool function
      waitForInput && continue
    fi

    if ! rotatePoolKeys "${pool_name}"; then
      waitForInput && continue
    fi

    echo
    say "Pool KES keys successfully updated"
    say "New KES start period  : ${current_kes_period}" "log"
    say "KES keys will expire  : $(( current_kes_period + MAX_KES_EVOLUTIONS )) - ${expiration_date}" "log"
    echo
    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
      say "Copy updated files to pool node replacing existing files:" "log"
      say "${pool_hotkey_sk_file}" "log"
      say "${pool_opcert_file}" "log"
      echo
    fi
    say "Restart your pool node for changes to take effect"

    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput && continue

    ;; ###################################################################

    decrypt)

    clear
    say " >> POOL >> DECRYPT" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo

    say "# Select pool to decrypt"
    if ! selectPool "all"; then # ${pool_name} populated by selectPool function
      waitForInput && continue
    fi

    filesUnlocked=0
    keysDecrypted=0

    say "# Removing write protection from all pool files" "log"
    while IFS= read -r -d '' file; do
      if [[ ${ENABLE_CHATTR} = true && $(lsattr -R "$file") =~ -i- ]]; then
        sudo chattr -i "${file}"
      fi
      chmod 600 "${file}"
      filesUnlocked=$((++filesUnlocked))
      say "${file}"
    done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    echo
    say "# Decrypting GPG encrypted pool files" "log"
    echo
    if ! getPassword; then # $password variable populated by getPassword function
      say "\n\n" && say "${FG_RED}ERROR${NC}: password input aborted!"
      waitForInput && continue
    fi
    while IFS= read -r -d '' file; do
      decryptFile "${file}" "${password}" && \
      chmod 600 "${file::-4}" && \
      keysDecrypted=$((++keysDecrypted))
    done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
    unset password

    echo
    say "Pool decrypted:  ${FG_GREEN}${pool_name}${NC}" "log"
    say "Files unlocked:  ${filesUnlocked}" "log"
    say "Files decrypted: ${keysDecrypted}" "log"
    if [[ ${filesUnlocked} -ne 0 || ${keysDecrypted} -ne 0 ]]; then
      echo
      say "${FG_YELLOW}Pool files are now unprotected${NC}" "log"
      say "Use 'POOL >> ENCRYPT / LOCK' to re-lock"
    fi
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput && continue

    ;; ###################################################################

    encrypt)

    clear
    say " >> POOL >> ENCRYPT" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo

    say "# Select pool to encrypt"
    if ! selectPool "all"; then # ${pool_name} populated by selectPool function
      waitForInput && continue
    fi

    filesLocked=0
    keysEncrypted=0

    say "# Encrypting sensitive pool keys with GPG" "log"
    echo
    if ! getPassword confirm; then # $password variable populated by getPassword function
      say "\n\n" && say "${FG_RED}ERROR${NC}: password input aborted!"
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
    say "# Write protecting all pool files with 400 permission and if enabled 'chattr +i'" "log"
    while IFS= read -r -d '' file; do
      chmod 400 "$file"
      if [[ ${ENABLE_CHATTR} = true && ! $(lsattr -R "$file") =~ -i- ]]; then
        sudo chattr +i "$file"
      fi
      filesLocked=$((++filesLocked))
      say "$file"
    done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    echo
    say "Pool encrypted:  ${FG_GREEN}${pool_name}${NC}" "log"
    say "Files locked:    ${filesLocked}" "log"
    say "Files encrypted: ${keysEncrypted}" "log"
    if [[ ${filesLocked} -ne 0 || ${keysEncrypted} -ne 0 ]]; then
      echo
      say "${FG_BLUE}Pool files are now protected${NC}" "log"
      say "Use 'POOL >> DECRYPT / UNLOCK' to unlock"
    fi
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput && continue

    ;; ###################################################################

  esac
  
  ;; ###################################################################

  signTx)
  
  clear
  say " >> SIGN TX" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo
  say "Enter path for Tx file to sign"
  waitForInput "Press any key to open the file explorer"
  fileDialog 0 "Enter path for Tx file to sign"
  say "${FG_CYAN}${file}${NC}\n" "log"
  tx_raw=${file}
  [[ -z "${tx_raw}" ]] && continue
  if [[ ! -f "${tx_raw}" ]]; then
    say "${FG_RED}ERROR${NC}: file not found: ${tx_raw}"
    waitForInput && continue
  fi
  
  say "# Sign the transaction with all keys needed"
  ofl_sign_keys=()
  say "\nEnter path to signing key files"
  waitForInput "Press any key to open the file explorer"
  while true; do
    fileDialog 0 "Enter path to signing key file" "${WALLET_FOLDER}/"
    if [[ -z "${file}" ]]; then
      say "${FG_YELLOW}EMPTY${NC}: no file selected, how do you want to proceed?"
    elif [[ ! -f "${file}" ]]; then
      say "${FG_RED}ERROR${NC}: file not found, please try again! [${file}]"
    else
      ofl_sign_keys+=( "${file}" )
      say "${FG_GREEN}${file}${NC} added!" "log"
    fi
    say "Add more keys?"
    select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
    case $? in
      0) echo && break ;;
      1) : ;;
      2) continue 2 ;;
    esac
  done
  echo

  if signTx "${tx_raw}" "${ofl_sign_keys[@]}"; then
    say "Tx file successfully signed and available at: ${FG_CYAN}${tx_signed}${NC}" "log"
    say "Transfer file to online CNTools and use 'Submit Tx' option to submit pool registration transaction on chain"
  fi
  
  waitForInput && continue

  ;; ###################################################################
  
  submitTx)
  
  clear
  say " >> SUBMIT TX" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

  if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
    say "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
    waitForInput && continue
  fi
  echo
  say "Please enter signed Tx file to submit"
  waitForInput "Press any key to open the file explorer"
  fileDialog 0 "Please enter signed Tx file to submit"
  say "${FG_CYAN}${file}${NC}" "log"
  echo
  [[ -z "${file}" ]] && continue
  if [[ ! -f "${file}" ]]; then
    say "${FG_RED}ERROR${NC}: file not found: ${file}"
    waitForInput && continue
  fi

  if submitTx "${file}"; then
    say "${FG_CYAN}${file}${NC} successfully submitted!" "log"
  fi
  
  waitForInput && continue

  ;; ###################################################################
  
  metadata)

  clear
  say " >> FUNDS >> POST METADATA" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

  if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
    say "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
    waitForInput && continue
  else
    if ! selectOpMode; then continue; fi
  fi
  echo
  
  say "Select the type of metadata to post on-chain"
  say "ref: https://github.com/input-output-hk/cardano-node/blob/master/doc/reference/tx-metadata.md"
  select_opt "[n] No JSON Schema (default)" "[d] Detailed JSON Schema" "[c] Raw CBOR"
  case $? in
    0) metatype="no-schema" ;;
    1) metatype="detailed-schema" ;;
    2) metatype="cbor" ;;
  esac

  if [[ ${metatype} = "cbor" ]]; then
    fileDialog 0 "Enter path to raw CBOR metadata file"
    metafile="${file}"
    say "${metafile}\n"
  else
    metafile="${TMP_FOLDER}/metadata.json"
    say "\nDo you want to select a metadata file, enter URL to metadata file, or enter/paste metadata content?"
    select_opt "[f] File" "[u] URL" "[e] Enter"
    case $? in
      0) tput sc
         fileDialog 0 "Enter path to JSON metadata file"
         metafile="${file}"
         if [[ ! -f "${metafile}" ]] || ! jq -er . "${metafile}" &>/dev/null; then
           say "${FG_RED}ERROR${NC}: invalid JSON format or file not found"
           say "${metafile}"
           waitForInput && continue
         fi
         tput rc && tput ed
         say "${metafile}:\n$(cat "${metafile}")\n"
         ;;
      1) tput sc && echo
         read -r -p "Enter URL to JSON metadata file: " meta_json_url
         if [[ ! "${meta_json_url}" =~ https?://.* ]]; then
           say "${FG_RED}ERROR${NC}: invalid URL format"
           waitForInput && continue
         fi
         if ! curl -sL -m ${CURL_TIMEOUT} -o "${metafile}" ${meta_json_url} || ! jq -er . "${metafile}" &>/dev/null; then
           say "${FG_RED}ERROR${NC}: metadata download failed, please make sure the URL point to a valid JSON file!"
           waitForInput && continue
         fi
         tput rc && tput ed
         say "Metadata file successfully downloaded to: ${metafile}"
         ;;
      2) tput sc
         DEFAULTEDITOR="$(command -v nano &>/dev/null && echo 'nano' || echo 'vi')"
         say "\nPaste or enter the metadata text, opening text editor ${FG_CYAN}${DEFAULTEDITOR}${NC}"
         say "${FG_YELLOW}Please don't change default file path when saving${NC}"
         waitForInput "press any key to open ${DEFAULTEDITOR}"
         ${DEFAULTEDITOR} "${metafile}"
         if [[ ! -f "${metafile}" ]] || ! jq -er . "${metafile}" &>/dev/null; then
           say "${FG_RED}ERROR${NC}: invalid JSON format or file not found"
           say "${metafile}"
           waitForInput && continue
         fi
         tput rc && tput ed
         say "Metadata file successfully saved to: ${metafile}"
         ;;
    esac
  fi

  say "\n# Select wallet"
  if [[ ${op_mode} = "online" ]]; then
    if ! selectWallet "balance" "${WALLET_PAY_SK_FILENAME}"; then # ${wallet_name} populated by selectWallet function
      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
    fi
  else
    if ! selectWallet "balance"; then # ${wallet_name} populated by selectWallet function
      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitForInput; continue
    fi
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
    say "Select source wallet address"
    if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
      say "$(printf "%s\t\t${FG_CYAN}%s${NC} ADA" "Funds :"  "$(formatLovelace ${base_lovelace})")" "log"
      say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")" "log"
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
      say "$(printf "%s\t${FG_CYAN}%s${NC} ADA" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")" "log"
    fi
  elif [[ ${base_lovelace} -gt 0 ]]; then
    addr="${base_addr}"
    if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
      say "$(printf "%s\t\t${FG_CYAN}%s${NC} ADA" "Funds :"  "$(formatLovelace ${base_lovelace})")" "log"
    fi
  else
    say "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
    waitForInput && continue
  fi

  payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"

  if ! sendMetadata "${addr}" "${payment_sk_file}" "${metafile}" "${metatype}"; then
    waitForInput && continue
  fi

  say "${FG_YELLOW}Waiting for metadata transaction to be recorded on chain${NC}"
  if ! waitNewBlockCreated; then
    waitForInput && continue
  fi

  getBalance ${addr}

  while [[ ${lovelace} -ne ${newBalance} ]]; do
    say "${FG_YELLOW}WARN${NC}: Balance mismatch, transaction not included in latest block... waiting for next block!"
    say "$(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance})" 1
    if ! waitNewBlockCreated; then
      break
    fi
    getBalance ${addr}
  done

  if [[ ${lovelace} -ne ${newBalance} ]]; then
    waitForInput && continue
  fi

  echo
  say "Metadata successfully posted on-chain" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  
  waitForInput && continue

  ;; ###################################################################

  blocks)

  clear
  say " >> BLOCKS" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

  if [[ ! -f "${BLOCKLOG_DB}" ]]; then
    say "${FG_RED}ERROR${NC}: blocklog db not found: ${BLOCKLOG_DB}"
    say "please follow instructions at guild website to deploy CNCLI and logMonitor services"
    say "https://cardano-community.github.io/guild-operators/#/Scripts/cncli"
    waitForInput && continue
  elif ! command -v sqlite3 >/dev/null; then
    say "${FG_RED}ERROR${NC}: sqlite3 not found!"
    say "please also follow instructions at guild website to deploy CNCLI and logMonitor services"
    say "https://cardano-community.github.io/guild-operators/#/Scripts/cncli"
    waitForInput && continue
  fi
  current_epoch=$(getEpoch)
  say "Current epoch: ${FG_CYAN}${current_epoch}${NC}\n"
  say "Show a block summary for all epochs or a detailed view for a specific epoch?"
  select_opt "[s] Summary" "[e] Epoch" "[Esc] Cancel"
  case $? in
    0) echo && read -r -p "Enter number of epochs to show (enter for 10): " epoch_enter
       epoch_enter=${epoch_enter:-10}
       if ! [[ ${epoch_enter} =~ ^[0-9]+$ ]]; then
         say "\n${FG_RED}ERROR${NC}: not a number"
         waitForInput && continue
       fi
       view=1; view_output="${FG_CYAN}[b] Block View${NC} | [i] Info"
       while true; do
         clear
         say " >> BLOCKS"
         say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
         current_epoch=$(getEpoch)
         say "Current epoch: ${FG_CYAN}${current_epoch}${NC}\n"
         if [[ ${view} -eq 1 ]]; then
           [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=$((current_epoch+1)) LIMIT 1);" 2>/dev/null) -eq 1 ]] && ((current_epoch++))
           first_epoch=$(( current_epoch - epoch_enter ))
           [[ ${first_epoch} -lt 0 ]] && first_epoch=0
           
           ideal_len=$(sqlite3 "${BLOCKLOG_DB}" "SELECT LENGTH(epoch_slots_ideal) FROM epochdata WHERE epoch BETWEEN ${first_epoch} and ${current_epoch} ORDER BY LENGTH(epoch_slots_ideal) DESC LIMIT 1;")
           [[ ${ideal_len} -lt 5 ]] && ideal_len=5
           luck_len=$(sqlite3 "${BLOCKLOG_DB}" "SELECT LENGTH(max_performance) FROM epochdata WHERE epoch BETWEEN ${first_epoch} and ${current_epoch} ORDER BY LENGTH(max_performance) DESC LIMIT 1;")
           [[ $((luck_len+1)) -le 4 ]] && luck_len=4 || luck_len=$((luck_len+1))
           printf '|'; printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" | tr " " "="; printf '|\n'
           printf "| %-5s | %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_CYAN}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "Epoch" "Leader" "Ideal" "Luck" "Adopted" "Confirmed" "Missed" "Ghosted" "Stolen" "Invalid"
           printf '|'; printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" | tr " " "="; printf '|\n'
           
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
             printf "| %-5s | %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_CYAN}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "${current_epoch}" "${leader_cnt}" "${epoch_stats[0]}" "${epoch_stats[1]}" "${adopted_cnt}" "${confirmed_cnt}" "${missed_cnt}" "${ghosted_cnt}" "${stolen_cnt}" "${invalid_cnt}"
             ((current_epoch--))
           done
           printf '|'; printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" | tr " " "="; printf '|\n'
         else
           say "Block Status:\n"
           say "Leader    - Scheduled to make block at this slot"
           say "Ideal     - Expected/Ideal number of blocks assigned based on active stake (sigma)"
           say "Luck      - Leader slots assigned vs Ideal slots for this epoch"
           say "Adopted   - Block created successfully"
           say "Confirmed - Block created validated to be on-chain with the certainty"
           say "            set in 'cncli.sh' for 'CONFIRM_BLOCK_CNT'"
           say "Missed    - Scheduled at slot but no record of it in cncli DB and no"
           say "            other pool has made a block for this slot"
           say "Ghosted   - Block created but marked as orphaned and no other pool has made"
           say "            a valid block for this slot, height battle or block propagation issue"
           say "Stolen    - Another pool has a valid block registered on-chain for the same slot"
           say "Invalid   - Pool failed to create block, base64 encoded error message"
           say "            can be decoded with 'echo <base64 hash> | base64 -d | jq -r'"
         fi
         echo
         
         say "[h] Home | ${view_output} | [*] Refresh"
         read -rsn1 key
         case ${key} in
           h ) continue 2 ;;
           b ) view=1; view_output="${FG_CYAN}[b] Block View${NC} | [i] Info" ;;
           i ) view=2; view_output="[b] Block View | ${FG_CYAN}[i] Info${NC}" ;;
           * ) continue ;;
         esac
       done
       ;;
    1) [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=$((current_epoch+1)) LIMIT 1);" 2>/dev/null) -eq 1 ]] && say "\n${FG_YELLOW}Leader schedule for next epoch[$((current_epoch+1))] available${NC}"
       echo && read -r -p "Enter epoch to list (enter for current): " epoch_enter
       [[ -z "${epoch_enter}" ]] && epoch_enter=${current_epoch}
       if [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=${epoch_enter} LIMIT 1);" 2>/dev/null) -eq 0 ]]; then
         say "No blocks in epoch ${epoch_enter}"
         waitForInput && continue
       fi
       view=1; view_output="${FG_CYAN}[1] View 1${NC} | [2] View 2 | [3] View 3 | [i] Info"
       while true; do
         clear
         say " >> BLOCKS"
         say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
         current_epoch=$(getEpoch)
         say "Current epoch: ${FG_CYAN}${current_epoch}${NC}\n"
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
         printf '|'; printf "%$((6+ideal_len+luck_len+7+9+6+7+6+7+24+2))s" | tr " " "="; printf '|\n'
         printf "| %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_CYAN}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "Leader" "Ideal" "Luck" "Adopted" "Confirmed" "Missed" "Ghosted" "Stolen" "Invalid"
         printf '|'; printf "%$((6+ideal_len+luck_len+7+9+6+7+6+7+24+2))s" | tr " " "="; printf '|\n'
         printf "| %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_CYAN}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" "${leader_cnt}" "${epoch_stats[0]}" "${epoch_stats[1]}" "${adopted_cnt}" "${confirmed_cnt}" "${missed_cnt}" "${ghosted_cnt}" "${stolen_cnt}" "${invalid_cnt}"
         printf '|'; printf "%$((6+ideal_len+luck_len+7+9+6+7+6+7+24+2))s" | tr " " "="; printf '|\n'
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
           printf '|'; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+17))s" | tr " " "="; printf '|\n'
           printf "| %-${#leader_cnt}s | %-${status_len}s | %-${block_len}s | %-${slot_len}s | %-${slot_in_epoch_len}s | %-${at_len}s |\n" "#" "Status" "Block" "Slot" "SlotInEpoch" "Scheduled At"
           printf '|'; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+17))s" | tr " " "="; printf '|\n'
           while IFS='|' read -r status block slot slot_in_epoch at; do
             at=$(TZ="${BLOCKLOG_TZ}" date '+%F %T %Z' --date="${at}")
             [[ ${block} -eq 0 ]] && block="-"
             printf "| %-${#leader_cnt}s | %-${status_len}s | %-${block_len}s | %-${slot_len}s | %-${slot_in_epoch_len}s | %-${at_len}s |\n" "${block_cnt}" "${status}" "${block}" "${slot}" "${slot_in_epoch}" "${at}"
             ((block_cnt++))
           done < <(sqlite3 "${BLOCKLOG_DB}" "SELECT status, block, slot, slot_in_epoch, at FROM blocklog WHERE epoch=${epoch_enter} ORDER BY slot;" 2>/dev/null)
           printf '|'; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+17))s" | tr " " "="; printf '|\n'
         elif [[ ${view} -eq 2 ]]; then
           printf '|'; printf "%$((${#leader_cnt}+status_len+slot_len+size_len+hash_len+14))s" | tr " " "="; printf '|\n'
           printf "| %-${#leader_cnt}s | %-${status_len}s | %-${slot_len}s | %-${size_len}s | %-${hash_len}s |\n" "#" "Status" "Slot" "Size" "Hash"
           printf '|'; printf "%$((${#leader_cnt}+status_len+slot_len+size_len+hash_len+14))s" | tr " " "="; printf '|\n'
           while IFS='|' read -r status slot size hash; do
             [[ ${size} -eq 0 ]] && size="-"
             [[ -z ${hash} ]] && hash="-"
             printf "| %-${#leader_cnt}s | %-${status_len}s | %-${slot_len}s | %-${size_len}s | %-${hash_len}s |\n" "${block_cnt}" "${status}" "${slot}" "${size}" "${hash}"
             ((block_cnt++))
           done < <(sqlite3 "${BLOCKLOG_DB}" "SELECT status, slot, size, hash FROM blocklog WHERE epoch=${epoch_enter} ORDER BY slot;" 2>/dev/null)
           printf '|'; printf "%$((${#leader_cnt}+status_len+slot_len+size_len+hash_len+14))s" | tr " " "="; printf '|\n'
         elif [[ ${view} -eq 3 ]]; then
           printf '|'; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+size_len+hash_len+23))s" | tr " " "="; printf '|\n'
           printf "| %-${#leader_cnt}s | %-${status_len}s | %-${block_len}s | %-${slot_len}s | %-${slot_in_epoch_len}s | %-${at_len}s | %-${size_len}s | %-${hash_len}s |\n" "#" "Status" "Block" "Slot" "SlotInEpoch" "Scheduled At" "Size" "Hash"
           printf '|'; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+size_len+hash_len+23))s" | tr " " "="; printf '|\n'
           while IFS='|' read -r status block slot slot_in_epoch at size hash; do
             at=$(TZ="${BLOCKLOG_TZ}" date '+%F %T %Z' --date="${at}")
             [[ ${block} -eq 0 ]] && block="-"
             [[ ${size} -eq 0 ]] && size="-"
             [[ -z ${hash} ]] && hash="-"
             printf "| %-${#leader_cnt}s | %-${status_len}s | %-${block_len}s | %-${slot_len}s | %-${slot_in_epoch_len}s | %-${at_len}s | %-${size_len}s | %-${hash_len}s |\n" "${block_cnt}" "${status}" "${block}" "${slot}" "${slot_in_epoch}" "${at}" "${size}" "${hash}"
             ((block_cnt++))
           done < <(sqlite3 "${BLOCKLOG_DB}" "SELECT status, block, slot, slot_in_epoch, at, size, hash FROM blocklog WHERE epoch=${epoch_enter} ORDER BY slot;" 2>/dev/null)
           printf '|'; printf "%$((${#leader_cnt}+status_len+block_len+slot_len+slot_in_epoch_len+at_len+size_len+hash_len+23))s" | tr " " "="; printf '|\n'
         elif [[ ${view} -eq 4 ]]; then
           say "Block Status:\n"
           say "Leader    - Scheduled to make block at this slot"
           say "Ideal     - Expected/Ideal number of blocks assigned based on active stake (sigma)"
           say "Luck      - Leader slots assigned vs Ideal slots for this epoch"
           say "Adopted   - Block created successfully"
           say "Confirmed - Block created validated to be on-chain with the certainty"
           say "            set in 'cncli.sh' for 'CONFIRM_BLOCK_CNT'"
           say "Missed    - Scheduled at slot but no record of it in cncli DB and no"
           say "            other pool has made a block for this slot"
           say "Ghosted   - Block created but marked as orphaned and no other pool has made"
           say "            a valid block for this slot, height battle or block propagation issue"
           say "Stolen    - Another pool has a valid block registered on-chain for the same slot"
           say "Invalid   - Pool failed to create block, base64 encoded error message"
           say "            can be decoded with 'echo <base64 hash> | base64 -d | jq -r'"
         fi
         echo
         
         say "[h] Home | ${view_output} | [*] Refresh"
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
  say " >> UPDATE" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo
  say "Full changelog available at:\nhttps://cardano-community.github.io/guild-operators/#/Scripts/cntools-changelog"
  echo

  if curl -s -m ${CURL_TIMEOUT} -o "${TMP_FOLDER}"/cntools.library "${URL}/cntools.library"; then
    GIT_MAJOR_VERSION=$(grep -r ^CNTOOLS_MAJOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    GIT_MINOR_VERSION=$(grep -r ^CNTOOLS_MINOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    GIT_PATCH_VERSION=$(grep -r ^CNTOOLS_PATCH_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    if [[ "${CNTOOLS_MAJOR_VERSION}" != "${GIT_MAJOR_VERSION}" ]];then
      say "New major version available: ${FG_GREEN}${GIT_MAJOR_VERSION}.${GIT_MINOR_VERSION}.${GIT_PATCH_VERSION}${NC} (Current: ${CNTOOLS_VERSION})\n"
      say "${FG_RED}WARNING${NC}: Breaking changes were made to CNTools!"
      say "\nPlease read changelog available at the above URL carefully and then follow directions below"
																									 
      waitForInput "We will not overwrite your changes automatically, press any key for update instructions"
      say "\n\n1) Please use the built in Backup option in CNTools before proceeding"
      say "\n2) After backup, re-run updated prereqs.sh script with -o -s -f switches to force overwrite script files, info and directions available at:"
      say "   https://cardano-community.github.io/guild-operators/#/basics?id=pre-requisites"
      say "\n3) As the last step, restore any modified parameters in cntools.config / env if needed"
    elif [[ "${CNTOOLS_MINOR_VERSION}" != "${GIT_MINOR_VERSION}" || "${CNTOOLS_PATCH_VERSION}" != "${GIT_PATCH_VERSION}" ]];then
      if [[ "${GIT_PATCH_VERSION}" -eq 999  ]]; then
        ((GIT_MAJOR_VERSION++))
        GIT_MINOR_VERSION=0
        GIT_PATCH_VERSION=0
      fi
      say "New version available: ${FG_GREEN}${GIT_MAJOR_VERSION}.${GIT_MINOR_VERSION}.${GIT_PATCH_VERSION}${NC} (Current: ${CNTOOLS_VERSION})\n"
      say "${FG_BLUE}INFO${NC} - The following files will be overwritten:"
      say "${CNODE_HOME}/scripts/cntools.sh"
      say "${CNODE_HOME}/scripts/cntools.library"
      say "\nProceed with update?"
      select_opt "[y] Yes" "[n] No"
      case $? in
        0) : ;; # do nothing
        1) continue ;; 
      esac
      say "\nApplying update..."
      if curl -s -m ${CURL_TIMEOUT} -o "${CNODE_HOME}/scripts/cntools.sh.tmp" "${URL}/cntools.sh" &&
         curl -s -m ${CURL_TIMEOUT} -o "${CNODE_HOME}/scripts/cntools.library.tmp" "${URL}/cntools.library" &&
         [[ $(grep "_HOME=" "${CNODE_HOME}"/scripts/env) =~ ^#?([^[:space:]]+)_HOME ]] &&
         sed -e "s@[C]NODE_HOME@${BASH_REMATCH[1]}_HOME@g" -i "${CNODE_HOME}/scripts/cntools".*.tmp; then
        mv -f "${CNODE_HOME}/scripts/cntools.sh.tmp" "${CNODE_HOME}/scripts/cntools.sh"
        mv -f "${CNODE_HOME}/scripts/cntools.library.tmp" "${CNODE_HOME}/scripts/cntools.library"
        chmod 755 "${CNODE_HOME}/scripts/cntools.sh"
        myExit 0 "Update applied successfully!\n\nPlease start CNTools again!"
      else
        say "\n${FG_RED}ERROR${NC}: update failed! :(\n"
      fi
    else
      say "${FG_GREEN}Up to Date${NC}: You're using the latest version. No updates required!"
    fi
  else
    say "\n${FG_RED}ERROR${NC}: download from GitHub failed, unable to perform version check!\n"
  fi
  waitForInput && continue
  
  ;; ###################################################################

  backup)

  clear
  say " >> BACKUP & RESTORE" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo
  say "Create or restore a backup of CNTools wallets, pools and configuration files"
  echo
  say "Backup or Restore?"
  select_opt "[b] Backup" "[r] Restore" "[Esc] Cancel"
  case $? in
    0) say "\nSelect backup directory(created if non existent)"
       waitForInput "Press any key to open the file explorer"
       dirDialog 0 "Select backup directory"
       [[ "${dir}" != */ ]] && backup_path="${dir}/" || backup_path="${dir}"
       say "${FG_GREEN}${backup_path}${NC}\n"
       if [[ ! "${backup_path}" =~ ^/[-0-9A-Za-z_]+ ]]; then
         say "${FG_RED}ERROR${NC}: invalid path, please specify the full path to backup directory (space not allowed)"
         waitForInput && continue
       fi
       mkdir -p "${backup_path}" # Create if missing
       if [[ ! -d "${backup_path}" ]]; then
         say "${FG_RED}ERROR${NC}: failed to create backup directory:"
         say "${backup_path}"
         waitForInput && continue
       fi
       
       missing_keys="false"
       excluded_files=()
       say "Include private keys in backup?"
       say "- No  > create a backup excluding wallets ${WALLET_PAY_SK_FILENAME}/${WALLET_STAKE_SK_FILENAME} and pools ${POOL_COLDKEY_SK_FILENAME}"
       say "- Yes > create a backup including all available files"
       select_opt "[n] No" "[y] Yes"
       case $? in
         0) excluded_files=(
              "--delete *${WALLET_PAY_SK_FILENAME}"
              "--delete *${WALLET_STAKE_SK_FILENAME}"
              "--delete *${POOL_COLDKEY_SK_FILENAME}"
            )
            backup_file="${backup_path}online_cntools-$(date '+%Y%m%d%H%M%S').tar"
            ;;
         1) backup_file="${backup_path}offline_cntools-$(date '+%Y%m%d%H%M%S').tar" ;;
       esac
       echo
       
       backup_list=(
         "${WALLET_FOLDER}"
         "${POOL_FOLDER}"
         "${BLOCKLOG_DIR}"
         "${CNODE_HOME}/files"
         "${CNODE_HOME}/scripts"
       )
       say "Backup job include:"
       for item in "${backup_list[@]}"; do
         say "${item}"
       done
       echo

       if ! tar cf "${backup_file}" --files-from <(ls -d "${backup_list[@]}" 2>/dev/null) &>/dev/null; then
         say "${FG_RED}ERROR${NC}: failure during backup creation :("
         waitForInput && continue
       fi
       if [[ ${#excluded_files[@]} -gt 0 ]]; then
         tar --wildcards --file="${backup_file}" ${excluded_files[*]} &>/dev/null
         gzip "${backup_file}" && backup_file+=".gz"
       else
         gzip "${backup_file}" && backup_file+=".gz"
         while IFS= read -r -d '' wallet; do # check for missing signing keys
           wallet_name=$(basename ${wallet})
           [[ -z "$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f -name "${WALLET_PAY_SK_FILENAME}*" -print)" ]] && \
             say "${FG_YELLOW}WARN${NC}: Wallet ${FG_GREEN}${wallet_name}${NC} missing file ${WALLET_PAY_SK_FILENAME}" && missing_keys="true"
           [[ -z "$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f -name "${WALLET_STAKE_SK_FILENAME}*" -print)" ]] && \
             say "${FG_YELLOW}WARN${NC}: Wallet ${FG_GREEN}${wallet_name}${NC} missing file ${WALLET_STAKE_SK_FILENAME}" && missing_keys="true"
         done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
         while IFS= read -r -d '' pool; do
           pool_name=$(basename ${pool})
           [[ -z "$(find "${pool}" -mindepth 1 -maxdepth 1 -type f -name "${POOL_COLDKEY_SK_FILENAME}*" -print)" ]] && \
             say "${FG_YELLOW}WARN${NC}: Pool ${FG_GREEN}${pool_name}${NC} missing file ${POOL_COLDKEY_SK_FILENAME}" && missing_keys="true"
         done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
         [[ ${missing_keys} = "true" ]] && echo
         say "Do you want to delete private keys?"
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
       
       say "Encrypt backup?"
       select_opt "[y] Yes" "[n] No"
       case $? in
         0) echo
            if getPassword confirm; then # $password variable populated by getPassword function
              encryptFile "${backup_file}" "${password}"
              backup_file="${backup_file}.gpg"
              unset password
            else
              say "${FG_RED}ERROR${NC}: password input aborted!"
            fi
            ;;
         1) : ;; # do nothing
       esac
       echo
       
       if [[ ${missing_keys} = "true" ]]; then
         say "${FG_YELLOW}There are wallets and/or pools with missing keys.\nIf removed in a previous backup, make sure to keep that master backup safe!${NC}"
         echo && say "Incremental backup file ${backup_file} successfully created" "log"
       else
         say "Backup file ${backup_file} successfully created" "log"
       fi
       ;;
    1) say "\nBackups created contain absolute path to files and directories"
       say "Restoring a backup does not replace existing files"
       say "Please restore to a temporary directory and copy files to restore to appropriate folders\n"
       say "Select file to restore"
       waitForInput "Press any key to open the file explorer"
       fileDialog 0 "Select backup file to restore"
       backup_file=${file}
       if [[ ! -f "${backup_file}" ]]; then
         say "${FG_RED}ERROR${NC}: file not found: ${backup_file}"
         waitForInput && continue
       fi
       say "${FG_GREEN}${backup_file}${NC}\n"
       say "Select/enter restore directory(created if non existent)"
       waitForInput "Press any key to open the file explorer"
       dirDialog 0 "Select restore directory"
       [[ "${dir}" != */ ]] && restore_path="${dir}/" || restore_path="${dir}"
       if [[ ! "${restore_path}" =~ ^/[-0-9A-Za-z_]+ ]]; then
         say "${FG_RED}ERROR${NC}: invalid path, please specify the full path to restore directory (space not allowed):"
         say "${restore_path}"
         waitForInput && continue
       fi
       say "${FG_GREEN}${restore_path}${NC}\n"
       restore_path="${restore_path}$(basename ${backup_file%%.*})"
       mkdir -p "${restore_path}" # Create restore directory
       if [[ ! -d "${restore_path}" ]]; then
         say "${FG_RED}ERROR${NC}: failed to create restore directory:"
         say "${restore_path}"
         waitForInput && continue
       fi
       if [ "${backup_file##*.}" = "gpg" ]; then
         say "\nBackup GPG encrypted, enter password to decrypt"
         if getPassword; then # $password variable populated by getPassword function
           decryptFile "${backup_file}" "${password}"
           backup_file="${backup_file%.*}"
           unset password
         else
           say "\n\n" && say "${FG_RED}ERROR${NC}: password input aborted!"
           waitForInput && continue
         fi
       fi
       if ! tar xfzk "${backup_file}" -C "${restore_path}" >/dev/null; then
         say "${FG_RED}ERROR${NC}: failure during backup restore :("
         waitForInput && continue
       fi
       echo
       say "Backup successfully restored to ${restore_path}" "log"
       ;;
    2) continue ;;
  esac
  
  waitForInput

  ;; ###################################################################

esac # main OPERATION
done # main loop
}

##############################################################

main "$@"
