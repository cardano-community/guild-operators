#!/bin/bash
#shellcheck disable=SC2009,SC2034,SC2059

###################################################################
# Automatically grab a few parameters                             #
# Do NOT modify, can be overridden 'User Variables' section below #
###################################################################

# The commands below will try to detect the information assuming you run single node on a machine. 
# Please override values if they dont match your system in the 'User Variables' section below 
[[ -z "${CNODE_HOME}" ]] && CNODE_HOME=/opt/cardano/cnode
[[ "$(ps -ef | grep "[c]ardano-node.*.${CNODE_HOME}")" =~ --port[[:space:]]([[:digit:]]+) ]]
CNODE_PORT=${BASH_REMATCH[1]:-6000} # default value: 6000
[[ "$(ps -ef | grep "[c]ardano-node.*.${CNODE_HOME}")" =~ --config[[:space:]]([^[:space:]]+) ]]
CONFIG="${BASH_REMATCH[1]:-${CNODE_HOME}/files/config.json}" # default value: /opt/cardano/cnode/files/config.json
if [[ -f "${CONFIG}" ]]; then
  EKG_PORT=$(jq -r '.hasEKG //empty' "${CONFIG}" 2>/dev/null)
else
  EKG_PORT=12788
fi
PROTOCOL=$(jq -r '.Protocol //empty' "${CONFIG}" 2>/dev/null)
[[ -d "${CNODE_HOME}/db/blocks" ]] && BLOCK_LOG_DIR="${CNODE_HOME}/db/blocks"

######################################
# User Variables - Change as desired #
# Leave as is if usure               #
######################################

#CNODE_HOME="/opt/cardano/cnode"          # Override default CNODE_HOME path
#CNODE_PORT=6000                          # Override automatic detection of node port
NODE_NAME="Cardano Node"                  # Change your node's name prefix here, keep at or below 19 characters for proper formatting
REFRESH_RATE=2                            # How often (in seconds) to refresh the view
#CONFIG="${CNODE_HOME}/files/config.json" # Override automatic detection of node config path
EKG_HOST=127.0.0.1                        # Set node EKG host
#EKG_PORT=12788                           # Override automatic detection of node EKG port
#PROTOCOL="Cardano"                       # Default: Combinator network. Leave commented if unsure.
#BLOCK_LOG_DIR="${CNODE_HOME}/db/blocks"  # CNTools Block Collector block dir set in cntools.config, override path if enabled and using non standard path

#####################################
# Do NOT Modify below               #
#####################################

tput smcup # Save screen
tput civis # Disable cursor
stty -echo # Disable user input

# Style
width=53
second_col=28
FG_RED=$(tput setaf 1)
FG_GREEN=$(tput setaf 2)
FG_YELLOW=$(tput setaf 3)
FG_BLUE=$(tput setaf 4)
FG_MAGENTA=$(tput setaf 5)
FG_CYAN=$(tput setaf 6)
STANDOUT=$(tput smso)
BOLD=$(tput bold)
VL="\\u2502"
HL="\\u2500"
NC=$(tput sgr0)

# Progressbar
char_marked=$(printf "\\u258C")
char_unmarked=$(printf "\\u2596")
granularity=50
granularity_small=25
step_size=$((100/granularity))
step_size_small=$((100/granularity_small))
bar_col_small=$((width - granularity_small))

# Lines
tdivider=$(printf "\\u250C" && printf "%0.s${HL}" $(seq $((width-1))) && printf "\\u2510")
mdivider=$(printf "\\u251C" && printf "%0.s${HL}" $(seq $((width-1))) && printf "\\u2524")
m2divider=$(printf "\\u251C" && printf "%0.s-" $(seq $((width-1))) && printf "\\u2524")
bdivider=$(printf "\\u2514" && printf "%0.s${HL}" $(seq $((width-1))) && printf "\\u2518")

# Title
title=$(printf "${FG_MAGENTA}${BOLD}Guild LiveView${NC}")

#####################################
# Helper functions                  #
#####################################

# Command     : myExit [message]
# Description : gracefully handle an exit and restore terminal to original state
myExit() {
  tput rmcup # restore screen
  [[ -n $2 ]] && echo -e "\n$2"
  stty echo # Enable user input
  tput cnorm # restore cursor
  echo -e "${NC}" # turn off all attributes
  exit "$1"
}

# General exit handler
cleanup() {
    err=$?
    trap '' INT TERM
    myExit $err "Guild LiveView terminated, cleaning up..."
}
sig_cleanup() {
    trap '' EXIT # some shells will call EXIT after the INT handler
    false # sets $?
    cleanup
}
trap sig_cleanup INT TERM

# Command     : waitForInput
# Description : wait for user keypress to quit, else do nothing if timeout expire
waitForInput() {
  ESC=$(printf "\033")
  if ! read -rsn1 -t ${REFRESH_RATE} key1; then return; fi
  [[ ${key1} = "${ESC}" ]] && read -rsn2 -t 0.3 key2 # read 2 more chars
  [[ ${key1} = "p" ]] && check_peers="true" && show_peers="true" && return
  [[ ${key1} = "h" ]] && show_peers="hide" && return
  [[ ${key1} = "q" ]] && myExit 0 "Guild LiveView stopped!"
  [[ ${key1} = "${ESC}" && ${key2} = "" ]] && myExit 0 "Guild LiveView stopped!"
  sleep 1
}



# Command    : showTimeLeft time_in_seconds
# Description: calculation of days, hours, minutes and seconds
timeLeft() {
  local T=$1
  local D=$((T/60/60/24))
  local H=$((T/60/60%24))
  local M=$((T/60%60))
  local S=$((T%60))
  (( D > 0 )) && printf '%d day' $D && {
    (( D > 1 )) && printf 's ' || printf ' '
  }
  printf '%02d:%02d:%02d' $H $M $S
}

# Command    : getEpoch
# Description: Offline calculation of current epoch based on genesis file
getShelleyTransitionEpoch() {
  calc_slot=0
  byron_epochs=${epochnum}
  shelley_epochs=0
  while [[ ${byron_epochs} -ge 0 ]]; do
    calc_slot=$(( (byron_epochs*byron_epoch_length) + (shelley_epochs*epoch_length) + slotinepoch ))
    [[ ${calc_slot} -eq ${slotnum} ]] && break
    ((byron_epochs--))
    ((shelley_epochs++))
  done
  if [[ "${nwmagic}" = "764824073" ]]; then
    shelley_transition_epoch=208
  elif [[ ${calc_slot} -ne ${slotnum} || ${shelley_epochs} -eq 0 ]]; then
    clear
    printf "\n ${FG_RED}Failed${NC} to calculate shelley transition epoch!"
    printf "\n Calculations might not work correctly until Shelley era is reached."
    printf "\n\n ${FG_BLUE}Press c to continue or any other key to quit${NC}"
    read -r -n 1 -s -p "" answer
    [[ "${answer}" != "c" ]] && myExit 1 "Guild LiveView terminated!"
    shelley_transition_epoch=0
  else
    shelley_transition_epoch=${byron_epochs}
  fi
}

# Command    : getEpoch
# Description: Offline calculation of current epoch based on genesis file
getEpoch() {
  current_time_sec=$(date -u +%s)
  if [[ "${PROTOCOL}" = "Cardano" ]]; then
    byron_end_time=$(( byron_genesis_start_sec + ( shelley_transition_epoch * byron_epoch_length * byron_slot_length ) ))
    echo $(( shelley_transition_epoch + ( (current_time_sec - byron_end_time) / slot_length / epoch_length ) ))
  else
    echo $(( (current_time_sec - shelley_genesis_start_sec) / slot_length / epoch_length ))
  fi
}

# Command    : getTimeUntilNextEpoch
# Description: Offline calculation of time in seconds until next epoch
timeUntilNextEpoch() {
  echo $(( (shelley_transition_epoch * byron_slot_length * byron_epoch_length) + ( ( $(getEpoch) + 1 - shelley_transition_epoch ) * slot_length * epoch_length ) - $(date -u +%s) + byron_genesis_start_sec ))
}

# Command    : getSlotTipRef
# Description: Get calculated slot number tip
getSlotTipRef() {
  current_time_sec=$(date -u +%s)
  if [[ "${PROTOCOL}" = "Cardano" ]]; then
    # Combinator network
    byron_slots=$(( shelley_transition_epoch * byron_epoch_length )) # since this point will only be reached once we're in Shelley phase
    byron_end_time=$(( byron_genesis_start_sec + ( shelley_transition_epoch * byron_epoch_length * byron_slot_length ) ))
    if [[ "${current_time_sec}" -lt "${byron_end_time}" ]]; then
      # In Byron phase
      echo $(( ( current_time_sec - byron_genesis_start_sec ) / byron_slot_length ))
    else
      # In Shelley phase
      echo $(( byron_slots + (( current_time_sec - byron_end_time ) / slot_length ) ))
    fi
  else
    # Shelley Mode only, no Byron slots
    echo $(( ( current_time_sec - shelley_genesis_start_sec ) / slot_length ))
  fi
}

# Command    : kesExpiration [pools remaining KES periods]
# Description: Calculate KES expiration
kesExpiration() {
  remaining_kes_periods=$1
  slot_in_epoch=$2
  current_time_sec=$(date -u +%s)
  expiration_time_sec=$(( current_time_sec - ( slot_length * slot_in_epoch ) + ( slot_length * slots_per_kes_period * remaining_kes_periods ) ))
  date '+%F %T Z' --date=@${expiration_time_sec}
}

endLine() {
  tput -S <<END
    el
    cup ${1} ${width}
END
  printf "${VL}\n"
}

# Command    : checkPeers [direction: in|out]
# Description: Check outgoing peers
#              Inspired by ping script from Martin @ ATADA pool
checkPeers() {
  # initialize variables
  peerCNT=0; peerCNT0=0; peerCNT1=0; peerCNT2=0; peerCNT3=0; peerCNT4=0
  peerPCT1=0; peerPCT2=0; peerPCT3=0; peerPCT4=0
  peerPCT1items=0; peerPCT2items=0; peerPCT3items=0; peerPCT4items=0
  peerRTTSUM=0; peerCNTSKIPPED=0; peerCNTABS=0; peerRTTAVG=0
  uniqPeers=()
  direction=$1
  
  pid=$(netstat -lnp 2>/dev/null | grep -e ":${CNODE_PORT}" | awk '{print $7}' | tail -n 1 | cut -d"/" -f1)
  [[ -z ${pid} || ${pid} = "-" ]] && return

  if [[ ${direction} = "out" ]]; then
    netstatPeers=$(netstat -np 2>/dev/null | grep -e "ESTABLISHED.* ${pid}/" | grep -v ":${CNODE_PORT}" | awk '{print $5}')
  else
    netstatPeers=$(netstat -np 2>/dev/null | grep -e "ESTABLISHED.* ${pid}/" | grep ":${CNODE_PORT}" | awk '{print $5}')
  fi
  netstatSorted=$(printf '%s\n' "${netstatPeers[@]}" | sort )
  
  # Sort/filter peers
  lastpeerIP=""; lastpeerPORT=""
  for peer in $netstatSorted; do
    peerIP=$(echo "${peer}" | cut -d: -f1); peerPORT=$(echo "${peer}" | cut -d: -f2)
    if [[ ! "$peerIP" = "$lastpeerIP" ]]; then
      lastpeerIP=${peerIP}
      lastpeerPORT=${peerPORT}
      uniqPeers+=("${peerIP}:${peerPORT} ")
      ((peerCNTABS++))
    fi
  done
  netstatPeers=$(printf '%s\n' "${uniqPeers[@]}")
  
  # Ping every node in the list
  for peer in ${netstatPeers}; do
    peerIP=$(echo "${peer}" | cut -d: -f1)
    peerPORT=$(echo "${peer}" | cut -d: -f2)

    if checkPEER=$(ping -c 2 -i 0.3 -w 1 "${peerIP}" 2>&1); then # Ping OK, show RTT
      peerRTT=$(echo "${checkPEER}" | tail -n 1 | cut -d/ -f5 | cut -d. -f1)
      ((peerCNT++))
      peerRTTSUM=$((peerRTTSUM + peerRTT))
    elif [[ ${direction} = "in" ]]; then # No need to continue with tcptraceroute for incoming connection as destination port is unknown
      peerRTT=-1
    else # Normal ping is not working, try tcptraceroute to the given port
      checkPEER=$(tcptraceroute -n -S -f 255 -m 255 -q 1 -w 1 "${peerIP}" "${peerPORT}" 2>&1 | tail -n 1)
      if [[ ${checkPEER} = *'[open]'* ]]; then
        peerRTT=$(echo "${checkPEER}" | awk '{print $4}' | cut -d. -f1)
        ((peerCNT++))
        peerRTTSUM=$((peerRTTSUM + peerRTT))
      else # Nope, no response
        peerRTT=-1
      fi
    fi

    # Update counters
      if [[ ${peerRTT} -ge 200 ]]; then ((peerCNT4++))
    elif [[ ${peerRTT} -ge 100 ]]; then ((peerCNT3++))
    elif [[ ${peerRTT} -ge 50  ]]; then ((peerCNT2++))
    elif [[ ${peerRTT} -ge 0   ]]; then ((peerCNT1++))
    else ((peerCNT0++)); fi
  done
  if [[ ${peerCNT} -gt 0 ]]; then 
    peerRTTAVG=$((peerRTTSUM / peerCNT))
  fi
  peerCNTSKIPPED=$((peerCNTABS - peerCNT - peerCNT0))
  
  peerMAX=0
  if [[ ${peerCNT} -gt 0 ]]; then
    peerPCT1=$(echo "scale=4;(${peerCNT1}/${peerCNT})*100" | bc -l)
    peerPCT1items=$(printf %.0f "$(echo "scale=4;${peerPCT1}/${step_size_small}" | bc -l)")
    peerPCT2=$(echo "scale=4;(${peerCNT2}/${peerCNT})*100" | bc -l)
    peerPCT2items=$(printf %.0f "$(echo "scale=4;${peerPCT2}/${step_size_small}" | bc -l)")
    peerPCT3=$(echo "scale=4;(${peerCNT3}/${peerCNT})*100" | bc -l)
    peerPCT3items=$(printf %.0f "$(echo "scale=4;${peerPCT3}/${step_size_small}" | bc -l)")
    peerPCT4=$(echo "scale=4;(${peerCNT4}/${peerCNT})*100" | bc -l)
    peerPCT4items=$(printf %.0f "$(echo "scale=4;${peerPCT4}/${step_size_small}" | bc -l)")
  fi
}

#####################################
# Static variables/calculations     #
#####################################
version=$("$(command -v cardano-node)" version)
node_version=$(grep "cardano-node" <<< "${version}" | cut -d ' ' -f2)
node_rev=$(grep "git rev" <<< "${version}" | cut -d ' ' -f3 | cut -c1-8)
check_peers="false"
show_peers="false"
line_end=0
data=$(curl -s -H 'Accept: application/json' http://${EKG_HOST}:${EKG_PORT}/ 2>/dev/null)
abouttolead=$(jq '.cardano.node.metrics.Forge["forge-about-to-lead"].int.val //0' <<< "${data}")
epochnum=$(jq '.cardano.node.ChainDB.metrics.epoch.int.val //0' <<< "${data}")
slotinepoch=$(jq '.cardano.node.ChainDB.metrics.slotInEpoch.int.val //0' <<< "${data}")
slotnum=$(jq '.cardano.node.ChainDB.metrics.slotNum.int.val //0' <<< "${data}")
kesremain=$(jq '.cardano.node.Forge.metrics.remainingKESPeriods.int.val //0' <<< "${data}")
[[ ${abouttolead} -gt 0 ]] && nodemode="Core" || nodemode="Relay"
kes_expiration="$(kesExpiration "${kesremain}" "${slotinepoch}")" # Wont change until KES rotation and node restart

#####################################
# Static genesis variables          #
#####################################
shelley_genesis_file=$(jq -r .ShelleyGenesisFile "${CONFIG}")
byron_genesis_file=$(jq -r .ByronGenesisFile "${CONFIG}")
nwmagic=$(jq -r .networkMagic < "${shelley_genesis_file}")
shelley_genesis_start=$(jq -r .systemStart "${shelley_genesis_file}")
shelley_genesis_start_sec=$(date --date="${shelley_genesis_start}" +%s)
epoch_length=$(jq -r .epochLength "${shelley_genesis_file}")
slot_length=$(jq -r .slotLength "${shelley_genesis_file}")
active_slots_coeff=$(jq -r .activeSlotsCoeff "${shelley_genesis_file}")
decentralisation=$(jq -r .protocolParams.decentralisationParam "${shelley_genesis_file}")
slots_per_kes_period=$(jq -r .slotsPerKESPeriod "${shelley_genesis_file}")
max_kes_evolutions=$(jq -r .maxKESEvolutions "${shelley_genesis_file}")
if [[ "${PROTOCOL}" = "Cardano" ]]; then
  byron_genesis_start_sec=$(jq -r .startTime "${byron_genesis_file}")
  byron_k=$(jq -r .protocolConsts.k "${byron_genesis_file}")
  byron_slot_length=$(( $(jq -r .blockVersionData.slotDuration "${byron_genesis_file}") / 1000 ))
  byron_epoch_length=$(( 10 * byron_k ))
  getShelleyTransitionEpoch
else
  shelley_transition_epoch=-1
fi
slot_interval=$(echo "(${slot_length} / ${active_slots_coeff} / ${decentralisation}) + 0.5" | bc -l | awk '{printf "%.0f\n", $1}')
#####################################

clear
tlines=$(tput lines) # set initial terminal lines
tcols=$(tput cols)   # set initial terminal columns

#####################################
# MAIN LOOP                         #
#####################################
while true; do
  [[ ${tlines} -ne $(tput lines) || ${tcols} -ne $(tput cols) ]] && redraw_peers=true || redraw_peers=false
  tlines=$(tput lines) # update terminal lines
  tcols=$(tput cols)   # update terminal columns
  [[ ${width} -ge $((tcols-1)) || ${line_end} -ge $((tlines-1)) ]] && clear
  while [[ ${width} -ge $((tcols-1)) ]]; do
    tput cup 1 1
    printf "${FG_RED}Terminal width too small!${NC}"
    tput cup 3 1
    printf "Please increase by ${FG_MAGENTA}$(( width - tcols + 2 ))${NC} columns"
    tput cup 5 1
    printf "${FG_CYAN}Use CTRL + C to force quit${NC}"
    sleep 2
    tlines=$(tput lines) # update terminal lines
    tcols=$(tput cols)   # update terminal columns
    redraw_peers=true
  done
  while [[ ${line_end} -ge $((tlines-1)) ]]; do
    tput cup 1 1
    printf "${FG_RED}Terminal height too small!${NC}"
    tput cup 3 1
    printf "Please increase by ${FG_MAGENTA}$(( line_end - tlines + 2 ))${NC} lines"
    tput cup 5 1
    printf "${FG_CYAN}Use CTRL + C to force quit${NC}"
    sleep 2
    tlines=$(tput lines) # update terminal lines
    tcols=$(tput cols)   # update terminal columns
    redraw_peers=true
  done
  
  line=0; tput cup 0 0 # reset position

  # Gather some data
  data=$(curl -s -H 'Accept: application/json' http://${EKG_HOST}:${EKG_PORT}/ 2>/dev/null)
  uptimens=$(jq '.cardano.node.metrics.upTime.ns.val //0' <<< "${data}")
  if ((uptimens<=0)); then
    myExit 1 "${FG_RED}COULD NOT CONNECT TO A RUNNING INSTANCE!${NC}\nPLEASE CHECK THE EKG PORT AND TRY AGAIN!"
  fi
  peers_in=$(netstat -an|awk "\$4 ~ /${CNODE_PORT}/"|grep -c ESTABLISHED)
  peers_out=$(jq '.cardano.node.BlockFetchDecision.peers.connectedPeers.int.val //0' <<< "${data}")
  blocknum=$(jq '.cardano.node.ChainDB.metrics.blockNum.int.val //0' <<< "${data}")
  epochnum=$(jq '.cardano.node.ChainDB.metrics.epoch.int.val //0' <<< "${data}")
  slotinepoch=$(jq '.cardano.node.ChainDB.metrics.slotInEpoch.int.val //0' <<< "${data}")
  slotnum=$(jq '.cardano.node.ChainDB.metrics.slotNum.int.val //0' <<< "${data}")
  density=$(jq -r '.cardano.node.ChainDB.metrics.density.real.val //0' <<< "${data}")
  density=$(printf "%3.3e" "${density}"| cut -d 'e' -f1)
  tx_processed=$(jq '.cardano.node.metrics.txsProcessedNum.int.val //0' <<< "${data}")
  mempool_tx=$(jq '.cardano.node.metrics.txsInMempool.int.val //0' <<< "${data}")
  mempool_bytes=$(jq '.cardano.node.metrics.mempoolBytes.int.val //0' <<< "${data}")
  kesperiod=$(jq '.cardano.node.Forge.metrics.currentKESPeriod.int.val //0' <<< "${data}")
  kesremain=$(jq '.cardano.node.Forge.metrics.remainingKESPeriods.int.val //0' <<< "${data}")
  isleader=$(jq '.cardano.node.metrics.Forge["node-is-leader"].int.val //0' <<< "${data}")
  forged=$(jq '.cardano.node.metrics.Forge.forged.int.val //0' <<< "${data}")
  adopted=$(jq '.cardano.node.metrics.Forge.adopted.int.val //0' <<< "${data}")
  didntadopt=$(jq '.cardano.node.metrics.Forge["didnt-adopt"].int.val //0' <<< "${data}")

  header_length=$(( ${#NODE_NAME} + ${#nodemode} + ${#node_version} + ${#node_rev} + 16 ))
  [[ ${header_length} -gt ${width} ]] && header_padding=0 || header_padding=$(( (width - header_length) / 2 ))
  printf "%${header_padding}s >> ${FG_GREEN}%s${NC} - ${FG_GREEN}%s${NC} : ${FG_BLUE}%s${NC} [${FG_BLUE}%s${NC}] <<\n" "" "${NODE_NAME}" "${nodemode}" "${node_version}" "${node_rev}"
  ((line++))

  ## Base section ##
  printf "${tdivider}"
  tput cup ${line} $(( width - 17 ))
  printf "\\u252C"
  tput cup $((++line)) 0
  
  printf "${VL} Uptime: $(timeLeft $(( uptimens/1000000000 )))"
  tput cup ${line} $(( width - 17 ))
  printf "${VL} ${title} ${VL}\n"
  ((line++))
  printf "${m2divider}"
  tput cup ${line} $(( width - 17 ))
  printf "\\u2514"
  printf "%0.s${HL}" $(seq 16)
  printf "\\u2524\n"
  ((line++))

  if [[ ${shelley_transition_epoch} = -1 || ${epochnum} -ge ${shelley_transition_epoch} ]]; then
    epoch_progress=$(echo "(${slotinepoch}/${epoch_length})*100" | bc -l)        # in Shelley era or Shelley only TestNet
  else
    epoch_progress=$(echo "(${slotinepoch}/${byron_epoch_length})*100" | bc -l)  # in Byron era
  fi
  printf "${VL} Epoch ${FG_BLUE}%s${NC} [%2.1f%%] (node)" "${epochnum}" "${epoch_progress}"
  endLine $((line++))
  printf "${VL} %s until epoch boundary (chain)" "$(timeLeft "$(timeUntilNextEpoch)")"
  endLine $((line++))

  epoch_items=$(( $(printf %.0f "${epoch_progress}") / step_size ))
  printf "${VL} ${FG_BLUE}"
  for i in $(seq 0 $((granularity-1))); do
    [[ $i -lt ${epoch_items} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
  done
  printf "${NC} ${VL}\n"; ((line++))
  
  printf "${VL}"; tput cup $((line++)) ${width}; printf "${VL}\n" # empty line
  
  tip_ref=$(getSlotTipRef)
  tip_diff=$(( tip_ref - slotnum ))
  printf "${VL} Block   : ${FG_BLUE}%s${NC}" "${blocknum}"
  tput cup ${line} ${second_col}
  printf "Tip (ref)  : ${FG_BLUE}%s${NC}" "${tip_ref}"
  endLine $((line++))
  printf "${VL} Slot    : ${FG_BLUE}%s${NC}" "${slotinepoch}"
  tput cup ${line} ${second_col}
  printf "Tip (node) : ${FG_BLUE}%s${NC}" "${slotnum}"
  endLine $((line++))
  printf "${VL} Density : ${FG_BLUE}%s${NC}" "${density}"
  tput cup ${line} ${second_col}
  if [[ ${tip_diff} -le $(( slot_interval * 2 )) ]]; then
    printf "Tip (diff) : ${FG_GREEN}%s${NC}" "-${tip_diff} :)"
  elif [[ ${tip_diff} -le $(( slot_interval * 3 )) ]]; then
    printf "Tip (diff) : %s" "-${tip_diff} :|"
  else
    printf "Tip (diff) : ${FG_RED}%s${NC}" "-${tip_diff} :("
  fi
  endLine $((line++))
  
  echo "${m2divider}"
  ((line++))
  
  printf "${VL} Processed TX     : ${FG_BLUE}%s${NC}" "${tx_processed}"
  tput cup ${line} $((second_col+7))
  printf "        In / Out"
  endLine $((line++))
  printf "${VL} Mempool TX/Bytes : ${FG_BLUE}%s${NC} / ${FG_BLUE}%s${NC}" "${mempool_tx}" "${mempool_bytes}"
  tput el; tput cup ${line} $((second_col+7))
  printf "Peers : ${FG_BLUE}%s${NC} / ${FG_BLUE}%s${NC}" "${peers_in}" "${peers_out}"
  endLine $((line++))
  
  ## Core section ##
  if [[ ${nodemode} = "Core" ]]; then
    echo "${mdivider}"
    ((line++))
    
    printf "${VL} KES current/remaining   : ${FG_BLUE}%s${NC} / " "${kesperiod}"
    if [[ ${kesremain} -le 0 ]]; then
      printf "${FG_RED}%s${NC}" "${kesremain}"
    elif [[ ${kesremain} -le 8 ]]; then
      printf "${FG_YELLOW}%s${NC}" "${kesremain}"
    else
      printf "${FG_BLUE}%s${NC}" "${kesremain}"
    fi
    endLine $((line++))
    printf "${VL} KES expiration date     : ${FG_BLUE}%s${NC}" "${kes_expiration}"
    endLine $((line++))
    
    echo "${m2divider}"
    ((line++))
    
    printf "${VL} %49s" "IsLeader/Adopted/Missed"
    endLine $((line++))
    printf "${VL} Blocks since node start : ${FG_BLUE}%s${NC} / " "${isleader}"
    if [[ ${adopted} -ne ${isleader} ]]; then
      printf "${FG_YELLOW}%s${NC} / " "${adopted}"
    else
      printf "${FG_BLUE}%s${NC} / " "${adopted}"
    fi
    if [[ ${didntadopt} -gt 0 ]]; then
      printf "${FG_RED}%s${NC}" "${didntadopt}"
    else
      printf "${FG_BLUE}%s${NC}" "${didntadopt}"
    fi
    endLine $((line++))
    
    if [[ -n ${BLOCK_LOG_DIR} ]]; then
      blocks_file="${BLOCK_LOG_DIR}/blocks_${epochnum}.json"
      if [[ -f "${blocks_file}" ]]; then
        isleader_epoch=$(jq -c '[.[].slot //empty] | length' "${blocks_file}")
        invalid_epoch=$(jq -c '[.[].hash //empty | select(startswith("Invalid"))] | length' "${blocks_file}")
        adopted_epoch=$(( $(jq -c '[.[].hash //empty] | length' "${blocks_file}") - invalid_epoch ))
      else
        isleader_epoch=0
        invalid_epoch=0
        adopted_epoch=0
      fi
      printf "${VL} Blocks this epoch       : ${FG_BLUE}%s${NC} / " "${isleader_epoch}"
      if [[ ${adopted_epoch} -ne ${isleader_epoch} ]]; then
        printf "${FG_YELLOW}%s${NC} / " "${adopted_epoch}"
      else
        printf "${FG_BLUE}%s${NC} / " "${adopted_epoch}"
      fi
      if [[ ${invalid_epoch} -gt 0 ]]; then
        printf "${FG_RED}%s${NC}" "${invalid_epoch}"
      else
        printf "${FG_BLUE}%s${NC}" "${invalid_epoch}"
      fi
      endLine $((line++))
    fi
  fi
  line_wo_peers=${line}
  
  ## Peer Analysis ##
  if [[ ${show_peers} = "true" ]]; then
    echo "${mdivider}"
    ((line++))
    
    if [[ ${check_peers} = "true" ]]; then
      redraw_peers=true
      tput ed
      printf "${VL} ${FG_YELLOW}Output peer analysis started... update paused${NC}"
      endLine ${line}
      echo "${bdivider}"
      checkPeers out
      # Save values
      peerCNT0_out=${peerCNT0}; peerCNT1_out=${peerCNT1}; peerCNT2_out=${peerCNT2}; peerCNT3_out=${peerCNT3}; peerCNT4_out=${peerCNT4}
      peerPCT1_out=${peerPCT1}; peerPCT2_out=${peerPCT2}; peerPCT3_out=${peerPCT3}; peerPCT4_out=${peerPCT4}
      peerPCT1items_out=${peerPCT1items}; peerPCT2items_out=${peerPCT2items}; peerPCT3items_out=${peerPCT3items}; peerPCT4items_out=${peerPCT4items}
      peerRTT_out=${peerRTT}; peerRTTAVG_out=${peerRTTAVG}; peerCNTABS_out=${peerCNTABS}; peerCNTSKIPPED_out=${peerCNTSKIPPED}
    fi
    
    if [[ ${redraw_peers} = "true" ]]; then

      tput cup ${line} 0
      
      printf "${VL}${STANDOUT} OUT ${NC}  RTT : Peers / Percent - %s" "$(date -u '+%F %T Z')"
      endLine $((line++))
      printf "${VL}    0-50ms : %5s / %.f%% ${FG_GREEN}" "${peerCNT1_out}" "${peerPCT1_out}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT1items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))

      printf "${VL}  50-100ms : %5s / %.f%% ${FG_YELLOW}" "${peerCNT2_out}" "${peerPCT2_out}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT2items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))

      printf "${VL} 100-200ms : %5s / %.f%% ${FG_RED}" "${peerCNT3_out}" "${peerPCT3_out}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT3items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))

      printf "${VL}   200ms < : %5s / %.f%% ${FG_MAGENTA}" "${peerCNT4_out}" "${peerPCT4_out}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT4items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))
        if [[ ${peerRTT_out} -ge 200 ]]; then printf "${VL}   Average : ${FG_MAGENTA}%s${NC} ms" "${peerRTTAVG_out}"
      elif [[ ${peerRTT_out} -ge 100 ]]; then printf "${VL}   Average : ${FG_RED}%s${NC} ms" "${peerRTTAVG_out}"
      elif [[ ${peerRTT_out} -ge 50  ]]; then printf "${VL}   Average : ${FG_YELLOW}%s${NC} ms" "${peerRTTAVG_out}"
      elif [[ ${peerRTT_out} -ge 0   ]]; then printf "${VL}   Average : ${FG_GREEN}%s${NC} ms" "${peerRTTAVG_out}"; fi
      endLine $((line++))
      
      echo "${m2divider}"
      ((line++))
      
      printf "${VL} Peers Total / Unreachable / Skipped : ${FG_BLUE}%s${NC} / " "${peerCNTABS_out}"
      [[ ${peerCNT0_out} -eq 0 ]] && printf "${FG_BLUE}%s${NC} / " "${peerCNT0_out}" || printf "${FG_RED}%s${NC} / " "${peerCNT0_out}"
      [[ ${peerCNTSKIPPED_out} -eq 0 ]] && printf "${FG_BLUE}%s${NC}" "${peerCNTSKIPPED_out}" || printf "${FG_YELLOW}%s${NC}" "${peerCNTSKIPPED_out}"
      endLine $((line++))
      
      echo "${m2divider}"
      ((line++))
      
      if [[ ${check_peers} = "true" ]]; then
        printf "${VL} ${FG_YELLOW}Input peer analysis started... update paused${NC}"
        endLine ${line}
        echo "${bdivider}"
        checkPeers in
        # Save values
        peerCNT0_in=${peerCNT0}; peerCNT1_in=${peerCNT1}; peerCNT2_in=${peerCNT2}; peerCNT3_in=${peerCNT3}; peerCNT4_in=${peerCNT4}
        peerPCT1_in=${peerPCT1}; peerPCT2_in=${peerPCT2}; peerPCT3_in=${peerPCT3}; peerPCT4_in=${peerPCT4}
        peerPCT1items_in=${peerPCT1items}; peerPCT2items_in=${peerPCT2items}; peerPCT3items_in=${peerPCT3items}; peerPCT4items_in=${peerPCT4items}
        peerRTT_in=${peerRTT}; peerRTTAVG_in=${peerRTTAVG}; peerCNTABS_in=${peerCNTABS}; peerCNTSKIPPED_in=${peerCNTSKIPPED}
      fi
      
      tput cup ${line} 0
      
      printf "${VL}${STANDOUT} In ${NC}   RTT : Peers / Percent"
      endLine $((line++))
      printf "${VL}    0-50ms : %5s / %.f%% ${FG_GREEN}" "${peerCNT1_in}" "${peerPCT1_in}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT1items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))

      printf "${VL}  50-100ms : %5s / %.f%% ${FG_YELLOW}" "${peerCNT2_in}" "${peerPCT2_in}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT2items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))

      printf "${VL} 100-200ms : %5s / %.f%% ${FG_RED}" "${peerCNT3_in}" "${peerPCT3_in}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT3items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))

      printf "${VL}   200ms < : %5s / %.f%% ${FG_MAGENTA}" "${peerCNT4_in}" "${peerPCT4_in}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT4items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))
        if [[ ${peerRTT_in} -ge 200 ]]; then printf "${VL}   Average : ${FG_MAGENTA}%s${NC} ms" "${peerRTTAVG_in}"
      elif [[ ${peerRTT_in} -ge 100 ]]; then printf "${VL}   Average : ${FG_RED}%s${NC} ms" "${peerRTTAVG_in}"
      elif [[ ${peerRTT_in} -ge 50  ]]; then printf "${VL}   Average : ${FG_YELLOW}%s${NC} ms" "${peerRTTAVG_in}"
      elif [[ ${peerRTT_in} -ge 0   ]]; then printf "${VL}   Average : ${FG_GREEN}%s${NC} ms" "${peerRTTAVG_in}"; fi
      endLine $((line++))
      
      echo "${m2divider}"
      ((line++))
      
      printf "${VL} Peers Total / Unreachable / Skipped : ${FG_BLUE}%s${NC} / " "${peerCNTABS_in}"
      [[ ${peerCNT0_in} -eq 0 ]] && printf "${FG_BLUE}%s${NC} / " "${peerCNT0_in}" || printf "${FG_RED}%s${NC} / " "${peerCNT0_in}"
      [[ ${peerCNTSKIPPED_in} -eq 0 ]] && printf "${FG_BLUE}%s${NC}" "${peerCNTSKIPPED_in}" || printf "${FG_YELLOW}%s${NC}" "${peerCNTSKIPPED_in}"
      endLine $((line++))
    fi
  fi
  
  if [[ ${show_peers} = "hide" ]]; then
    show_peers=false
    tput ed
    line_end=${line_wo_peers}
  elif [[ ${line_end} -lt ${line} ]]; then
    line_end=${line}
  fi
  tput cup ${line_end} 0
  echo "${bdivider}"
  printf " ${FG_YELLOW}[esc/q] Quit${NC} | ${FG_YELLOW}[p] Peer Analysis${NC}"
  if [[ "${check_peers}" = "true" ]]; then
    check_peers="false"
  fi
  if [[ "${show_peers}" = "true" ]]; then
    printf " | ${FG_YELLOW}[h] Hide Peers${NC}"
  else
    tput el
  fi
  waitForInput
done
