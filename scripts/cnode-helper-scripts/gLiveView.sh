#!/bin/bash
#shellcheck disable=SC2009,SC2034,SC2059,SC2206,SC2086,SC2015

GLV_VERSION=v1.1

######################################
# User Variables - Change as desired #
# Leave as is if usure               #
######################################

#CNODE_HOME="/opt/cardano/cnode"          # Override default CNODE_HOME path
#CNODE_PORT=6000                          # Override automatic detection of node port
NODE_NAME="Cardano Node"                  # Change your node's name prefix here, keep at or below 19 characters!
REFRESH_RATE=2                            # How often (in seconds) to refresh the view
#CONFIG="${CNODE_HOME}/files/config.json" # Override automatic detection of node config path
EKG_HOST=127.0.0.1                        # Set node EKG host
#EKG_PORT=12788                           # Override automatic detection of node EKG port
#PROTOCOL="Cardano"                       # Default: Combinator network (leave commented if unsure)
#BLOCK_LOG_DIR="${CNODE_HOME}/db/blocks"  # CNTools Block Collector block dir set in cntools.config, override path if enabled and using non standard path
LEGACY_MODE=false                         # (true|false) If enabled unicode box-drawing characters will be replaced by standard ASCII characters
THEME="dark"                              # dark  = suited for terminals with a dark background
                                          # light = suited for terminals with a bright background

#####################################
# Themes                            #
#####################################

setTheme() {
  if [[ ${THEME} = "dark" ]]; then
    style_title=${FG_MAGENTA}${BOLD}      # style of title
    style_base=${FG_WHITE}                # default color for text and lines
    style_values_1=${FG_CYAN}             # color of most live values
    style_values_2=${FG_GREEN}            # color of node name
    style_info=${FG_YELLOW}               # info messages
    style_status_1=${FG_GREEN}            # :)
    style_status_2=${FG_YELLOW}           # :|
    style_status_3=${FG_RED}              # :(
    style_status_4=${FG_MAGENTA}          # :((
  elif [[ ${THEME} = "light" ]]; then
    style_title=${FG_MAGENTA}${BOLD}      # style of title
    style_base=${FG_BLACK}                # default color for text and lines
    style_values_1=${FG_BLUE}             # color of most live values
    style_values_2=${FG_GREEN}            # color of node name
    style_info=${FG_YELLOW}               # info messages
    style_status_1=${FG_GREEN}            # :)
    style_status_2=${FG_YELLOW}           # :|
    style_status_3=${FG_RED}              # :(
    style_status_4=${FG_MAGENTA}          # :((
  else
    myExit 1 "Please specify a valid THEME name!"
  fi
}

#####################################
# Do NOT Modify below               #
#####################################

tput smcup # Save screen
tput civis # Disable cursor
stty -echo # Disable user input

# General exit handler
cleanup() {
  [[ -n $1 ]] && err=$1 || err=$?
  tput rmcup # restore screen
  tput cnorm # restore cursor
  tput sgr0  # turn off all attributes
  [[ -n ${exit_msg} ]] && echo -e "\n${exit_msg}\n" || echo -e "\nGuild LiveView terminated, cleaning up...\n"
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

usage() {
  cat <<EOF
Usage: $(basename "$0") [-l]
Guild LiveView - An alternative cardano-node LiveView

-l    Activate legacy mode - standard ASCII characters instead of box-drawing characters
EOF
}

while getopts :l opt; do
  case ${opt} in
    l )
      LEGACY_MODE="true"
      ;;
    \? )
      myExit 1 "$(usage)"
      ;;
    esac
done
shift $((OPTIND -1))

if ! command -v "ss" &>/dev/null; then
  myExit 1 "'ss' command missing, please install using latest prereqs.sh script or with your packet manager of choice.\nhttps://command-not-found.com/ss can be used to check package name to install."
elif ! command -v "tcptraceroute" &>/dev/null; then
  myExit 1 "'tcptraceroute' command missing, please install using latest prereqs.sh script or with your packet manager of choice.\nhttps://command-not-found.com/tcptraceroute can be used to check package name to install."
fi

#######################################################
# Version Check                                       #
#######################################################
clear
echo "Guild LiveView version check..."
URL="https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts"
if wget -q -T 10 -O /tmp/gLiveView.sh "${URL}/gLiveView.sh" 2>/dev/null; then
  GIT_VERSION=$(grep -r ^GLV_VERSION= /tmp/gLiveView.sh | cut -d'=' -f2)
  : "${GIT_VERSION:=v0.0}"
  if [[ "${GLV_VERSION}" != "${GIT_VERSION}" ]]; then
    echo -e "\nA new version of Guild LiveView is available"
    echo "Installed Version : ${GLV_VERSION}"
    echo "Available Version : ${GIT_VERSION}"
    echo -e "\nPress 'u' to update to latest version, or any other key to continue\n"
    read -r -n 1 -s -p "" answer
    if [[ "${answer}" = "u" ]]; then
      mv "${CNODE_HOME}/scripts/gLiveView.sh" "${CNODE_HOME}/scripts/gLiveView.sh.bkp_$(date +%s)"
      cp -f /tmp/gLiveView.sh "${CNODE_HOME}/scripts/gLiveView.sh"
      chmod 750 "${CNODE_HOME}/scripts/gLiveView.sh"
      myExit 0 "Update applied successfully!\n\nPlease start Guild LiveView again!"
    fi
  fi
else
  echo -e "\nFailed to download gLiveView.sh from GitHub, unable to perform version check!\n"
  read -r -n 1 -s -p "press any key to proceed" answer
fi

#######################################################
# Automatically grab a few parameters                 #
# Can be overridden in 'User Variables' section above #
#######################################################

# The commands below will try to detect the information assuming you run single node on a machine. 
# Please override values if they dont match your system in the 'User Variables' section below 
[[ ${#NODE_NAME} -gt 19 ]] && myExit 1 "Please keep node name at or below 19 characters in length!"
[[ ! ${REFRESH_RATE} =~ ^[0-9]+$ ]] && myExit 1 "Please set a valid refresh rate number!"
if [[ ${EKG_HOST} =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  OIFS=$IFS
  IFS='.'
  EKG_OCTETS=(${EKG_HOST})
  IFS=$OIFS
  if ! [[ ${EKG_OCTETS[0]} -le 255 && ${EKG_OCTETS[1]} -le 255 && ${EKG_OCTETS[2]} -le 255 && ${EKG_OCTETS[3]} -le 255 ]]; then
    myExit 1 "Not a valid IP range set for EKG host, please check configuration!"
  fi
else
  myExit 1 "Not a valid IP format set for EKG host, please check configuration!"
fi
[[ -z "${CNODE_HOME}" ]] && CNODE_HOME=/opt/cardano/cnode
if [[ -z "${CNODE_PORT}" ]]; then
  if [[ "$(ps -ef | grep "[c]ardano-node.*.${CNODE_HOME}")" =~ --port[[:space:]]([[:digit:]]+) ]]; then
    CNODE_PORT=${BASH_REMATCH[1]}
  else
    myExit 1 "Node port not set and automatic detection failed!"
  fi
fi
if [[ -z "${CONFIG}" ]]; then
  if [[ "$(ps -ef | grep "[c]ardano-node.*.${CNODE_HOME}")" =~ --config[[:space:]]([^[:space:]]+) ]]; then
    CONFIG=${BASH_REMATCH[1]}
  else
    myExit 1 "Node config not set and automatic detection failed!"
  fi
fi
if [[ -f "${CONFIG}" ]]; then
  if ! EKG_PORT=$(jq -er '.hasEKG' "${CONFIG}" 2>/dev/null); then
    myExit 1 "Could not get 'hasEKG' port from the node configuration file"
  fi
  if ! PROTOCOL=$(jq -er '.Protocol' "${CONFIG}" 2>/dev/null); then
    myExit 1 "Could not get 'Protocol' from the node configuration file"
  fi
else
  myExit 1 "Node config not found: ${CONFIG}"
fi
[[ -z ${BLOCK_LOG_DIR} && -d "${CNODE_HOME}/db/blocks" ]] && BLOCK_LOG_DIR="${CNODE_HOME}/db/blocks" # optional

# Style
width=53
second_col=28
FG_BLACK=$(tput setaf 0)
FG_RED=$(tput setaf 1)
FG_GREEN=$(tput setaf 2)
FG_YELLOW=$(tput setaf 3)
FG_BLUE=$(tput setaf 4)
FG_MAGENTA=$(tput setaf 5)
FG_CYAN=$(tput setaf 6)
FG_WHITE=$(tput setaf 7)
STANDOUT=$(tput smso)
BOLD=$(tput bold)

setTheme # call function to set theme colors
NC=$(tput sgr0 && printf "${style_base}") # reset style and set base color

# Progressbar
if [[ ${LEGACY_MODE} = "true" ]]; then
  char_marked="#"
  char_unmarked="."
else
  char_marked=$(printf "\\u258C")
  char_unmarked=$(printf "\\u2596")
fi
granularity=50
granularity_small=25
step_size=$((100/granularity))
step_size_small=$((100/granularity_small))
bar_col_small=$((width - granularity_small))

# Lines
if [[ ${LEGACY_MODE} = "true" ]]; then
  VL=$(printf "${NC}|")
  HL=$(printf "${NC}=")
  LVL=$(printf "${NC}|")
  RVL=$(printf "${NC}|")
  UHL=$(printf "${NC}=")
  DHL=$(printf "${NC}=")
  UR=$(printf "${NC}=")
  UL=$(printf "${NC}|")
  DR=$(printf "${NC}|")
  DL=$(printf "${NC}|")
  tdivider=$(printf "${NC}|" && printf "%0.s=" $(seq $((width-1))) && printf "|")
  mdivider=$(printf "${NC}|" && printf "%0.s=" $(seq $((width-1))) && printf "|")
  m2divider=$(printf "${NC}|" && printf "%0.s-" $(seq $((width-1))) && printf "|")
  m3divider=$(printf "${NC}|" && printf "%0.s- " $(seq $((width/2))) && printf "|")
  bdivider=$(printf "${NC}|" && printf "%0.s=" $(seq $((width-1))) && printf "|")
else
  VL=$(printf "${NC}\\u2502")
  HL=$(printf "${NC}\\u2500")
  LVL=$(printf "${NC}\\u2524")
  RVL=$(printf "${NC}\\u251C")
  UHL=$(printf "${NC}\\u2534")
  DHL=$(printf "${NC}\\u252C")
  UR=$(printf "${NC}\\u2514")
  UL=$(printf "${NC}\\u2518")
  DR=$(printf "${NC}\\u250C")
  DL=$(printf "${NC}\\u2510")
  tdivider=$(printf "${NC}\\u250C" && printf "%0.s\\u2500" $(seq $((width-1))) && printf "\\u2510")
  mdivider=$(printf "${NC}\\u251C" && printf "%0.s\\u2500" $(seq $((width-1))) && printf "\\u2524")
  m2divider=$(printf "${NC}\\u2502" && printf "%0.s-" $(seq $((width-1))) && printf "\\u2502")
  m3divider=$(printf "${NC}\\u2502" && printf "%0.s- " $(seq $((width/2))) && printf "\\u2502")
  bdivider=$(printf "${NC}\\u2514" && printf "%0.s\\u2500" $(seq $((width-1))) && printf "\\u2518")
fi

# Title
title="Guild LiveView ${GLV_VERSION}"

#####################################
# Helper functions                  #
#####################################

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

# Command    : getShelleyTransitionEpoch [1 = no user verification]
# Description: Calculate shelley transition epoch
getShelleyTransitionEpoch() {
  calc_slot=0
  byron_epochs=${epochnum}
  shelley_epochs=0
  while [[ ${byron_epochs} -ge 0 ]]; do
    calc_slot=$(( (byron_epochs*byron_epoch_length) + (shelley_epochs*epoch_length) + slot_in_epoch ))
    [[ ${calc_slot} -eq ${slotnum} ]] && break
    ((byron_epochs--))
    ((shelley_epochs++))
  done
  if [[ "${nwmagic}" = "764824073" ]]; then
    shelley_transition_epoch=208
  elif [[ ${calc_slot} -ne ${slotnum} || ${shelley_epochs} -eq 0 ]]; then
    if [[ $1 -ne 1 ]]; then
      clear
      printf "\n ${style_status_3}Failed${NC} to get shelley transition epoch, calculations will not work correctly!"
      printf "\n\n Possible causes:"
      printf "\n   - Node in startup mode"
      printf "\n   - Shelley era not reached"
      printf "\n After successful node boot or when sync to shelley era has been reached, calculations will be correct"
      printf "\n\n ${style_info}Press c to continue or any other key to quit${NC}"
      read -r -n 1 -s -p "" answer
      [[ "${answer}" != "c" ]] && myExit 1 "Guild LiveView terminated!"
    fi
    shelley_transition_epoch=-1
  else
    shelley_transition_epoch=${byron_epochs}
  fi
}

# Command    : getEpoch
# Description: Offline calculation of current epoch based on genesis file
getEpoch() {
  current_time_sec=$(date -u +%s)
  if [[ "${PROTOCOL}" = "Cardano" ]]; then
    [[ shelley_transition_epoch -eq -1 ]] && echo 0 && return
    byron_end_time=$(( byron_genesis_start_sec + ( shelley_transition_epoch * byron_epoch_length * byron_slot_length ) ))
    echo $(( shelley_transition_epoch + ( (current_time_sec - byron_end_time) / slot_length / epoch_length ) ))
  else
    echo $(( (current_time_sec - shelley_genesis_start_sec) / slot_length / epoch_length ))
  fi
}

# Command    : getTimeUntilNextEpoch
# Description: Offline calculation of time in seconds until next epoch
timeUntilNextEpoch() {
  current_time_sec=$(date -u +%s)
  if [[ "${PROTOCOL}" = "Cardano" ]]; then
    [[ shelley_transition_epoch -eq -1 ]] && echo 0 && return
    echo $(( (shelley_transition_epoch * byron_slot_length * byron_epoch_length) + ( ( $(getEpoch) + 1 - shelley_transition_epoch ) * slot_length * epoch_length ) - current_time_sec + byron_genesis_start_sec ))
  else
    echo $(( ( ( ( (current_time_sec - shelley_genesis_start_sec) / slot_length / epoch_length ) + 1 ) * slot_length * epoch_length ) - current_time_sec + shelley_genesis_start_sec ))
  fi
}

# Command    : getSlotTipRef
# Description: Get calculated slot number tip
getSlotTipRef() {
  current_time_sec=$(date -u +%s)
  if [[ "${PROTOCOL}" = "Cardano" ]]; then
    [[ shelley_transition_epoch -eq -1 ]] && echo 0 && return
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
  current_time_sec=$(date -u +%s)
  tip_ref=$(getSlotTipRef)
  expiration_time_sec=$(( current_time_sec - ( slot_length * (tip_ref % slots_per_kes_period) ) + ( slot_length * slots_per_kes_period * remaining_kes_periods ) ))
  kes_expiration=$(date '+%F %T Z' --date=@${expiration_time_sec})
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
  peerRTTSUM=0; peerCNTSKIPPED=0; peerCNTUnique=0; peerCNTABS=0; peerRTTAVG=0
  uniquePeers=()
  direction=$1

  if [[ ${direction} = "out" ]]; then
    netstatPeers=$(ss -tnp state established 2>/dev/null | grep "${pid}," | awk -v port=":${CNODE_PORT}" '$3 !~ port {print $4}')
  else
    netstatPeers=$(ss -tnp state established 2>/dev/null | grep "${pid}," | awk -v port=":${CNODE_PORT}" '$3 ~ port {print $4}')
  fi
  [[ -z ${netstatPeers} ]] && return
  
  netstatSorted=$(printf '%s\n' "${netstatPeers[@]}" | sort )
  peerCNTABS=$(wc -w <<< "${netstatPeers}")
  
  # Sort/filter peers
  lastpeerIP=""; lastpeerPORT=""
  for peer in ${netstatSorted}; do
    peerIP=$(echo "${peer}" | cut -d: -f1); peerPORT=$(echo "${peer}" | cut -d: -f2)
    if [[ ! "${peerIP}" = "${lastpeerIP}" ]]; then
      lastpeerIP=${peerIP}
      lastpeerPORT=${peerPORT}
      uniquePeers+=("${peerIP}:${peerPORT} ")
      ((peerCNTUnique++))
    fi
  done
  netstatPeers=$(printf '%s\n' "${uniquePeers[@]}")
  
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
  peerCNTSKIPPED=$(( peerCNTABS - peerCNTUnique ))
  
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
pid=$(ps -ef | grep "[-]-port ${CNODE_PORT}" | awk '{print $2}')
[[ -z ${pid} ]] && myExit 1 "Failed to locate cardano-node process ID, make sure CNODE_PORT is correctly set in script!"
check_peers="false"
show_peers="false"
line_end=0
data=$(curl -s -H 'Accept: application/json' "http://${EKG_HOST}:${EKG_PORT}/" 2>/dev/null)
epochnum=$(jq '.cardano.node.ChainDB.metrics.epoch.int.val //0' <<< "${data}")
slot_in_epoch=$(jq '.cardano.node.ChainDB.metrics.slotInEpoch.int.val //0' <<< "${data}")
slotnum=$(jq '.cardano.node.ChainDB.metrics.slotNum.int.val //0' <<< "${data}")
remaining_kes_periods=$(jq '.cardano.node.Forge.metrics.remainingKESPeriods.int.val //0' <<< "${data}")

#####################################
# Static genesis variables          #
#####################################
shelley_genesis_file=$(jq -r .ShelleyGenesisFile "${CONFIG}")
[[ ! ${shelley_genesis_file} =~ ^/ ]] && shelley_genesis_file="$(dirname "${CONFIG}")/${shelley_genesis_file}"
byron_genesis_file=$(jq -r .ByronGenesisFile "${CONFIG}")
[[ ! ${byron_genesis_file} =~ ^/ ]] && byron_genesis_file="$(dirname "${CONFIG}")/${byron_genesis_file}"
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
  shelley_transition_epoch=-2
fi
#####################################
slot_interval=$(echo "(${slot_length} / ${active_slots_coeff} / ${decentralisation}) + 0.5" | bc -l | awk '{printf "%.0f\n", $1}')
kesExpiration
#####################################

clear
tlines=$(tput lines) # set initial terminal lines
tcols=$(tput cols)   # set initial terminal columns
printf "${NC}"       # reset and set default color

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
    printf "${style_status_3}Terminal width too small!${NC}"
    tput cup 3 1
    printf "Please increase by ${style_info}$(( width - tcols + 2 ))${NC} columns"
    tput cup 5 1
    printf "${style_info}Use CTRL + C to force quit${NC}"
    sleep 2
    tlines=$(tput lines) # update terminal lines
    tcols=$(tput cols)   # update terminal columns
    redraw_peers=true
  done
  while [[ ${line_end} -ge $((tlines-1)) ]]; do
    tput cup 1 1
    printf "${style_status_3}Terminal height too small!${NC}"
    tput cup 3 1
    printf "Please increase by ${style_info}$(( line_end - tlines + 2 ))${NC} lines"
    tput cup 5 1
    printf "${style_info}Use CTRL + C to force quit${NC}"
    sleep 2
    tlines=$(tput lines) # update terminal lines
    tcols=$(tput cols)   # update terminal columns
    redraw_peers=true
  done
  
  line=0; tput cup 0 0 # reset position

  # Gather some data
  data=$(curl -s -H 'Accept: application/json' "http://${EKG_HOST}:${EKG_PORT}/" 2>/dev/null)
  uptimens=$(jq '.cardano.node.metrics.upTime.ns.val //0' <<< "${data}")
  if ((uptimens<=0)); then
    myExit 1 "${style_status_3}COULD NOT CONNECT TO A RUNNING INSTANCE!${NC}"
  fi
  peers_in=$(ss -tnp state established 2>/dev/null | grep "${pid}," | awk -v port=":${CNODE_PORT}" '$3 ~ port {print}' | wc -l)
  peers_out=$(jq '.cardano.node.BlockFetchDecision.peers.connectedPeers.int.val //0' <<< "${data}")
  blocknum=$(jq '.cardano.node.ChainDB.metrics.blockNum.int.val //0' <<< "${data}")
  epochnum=$(jq '.cardano.node.ChainDB.metrics.epoch.int.val //0' <<< "${data}")
  slot_in_epoch=$(jq '.cardano.node.ChainDB.metrics.slotInEpoch.int.val //0' <<< "${data}")
  slotnum=$(jq '.cardano.node.ChainDB.metrics.slotNum.int.val //0' <<< "${data}")
  density=$(jq -r '.cardano.node.ChainDB.metrics.density.real.val //0' <<< "${data}")
  density=$(printf "%3.3e" "${density}"| cut -d 'e' -f1)
  tx_processed=$(jq '.cardano.node.metrics.txsProcessedNum.int.val //0' <<< "${data}")
  mempool_tx=$(jq '.cardano.node.metrics.txsInMempool.int.val //0' <<< "${data}")
  mempool_bytes=$(jq '.cardano.node.metrics.mempoolBytes.int.val //0' <<< "${data}")
  kesperiod=$(jq '.cardano.node.Forge.metrics.currentKESPeriod.int.val //0' <<< "${data}")
  remaining_kes_periods=$(jq '.cardano.node.Forge.metrics.remainingKESPeriods.int.val //0' <<< "${data}")
  isleader=$(jq '.cardano.node.metrics.Forge["node-is-leader"].int.val //0' <<< "${data}")
  forged=$(jq '.cardano.node.metrics.Forge.forged.int.val //0' <<< "${data}")
  adopted=$(jq '.cardano.node.metrics.Forge.adopted.int.val //0' <<< "${data}")
  didntadopt=$(jq '.cardano.node.metrics.Forge["didnt-adopt"].int.val //0' <<< "${data}")
  about_to_lead=$(jq '.cardano.node.metrics.Forge["forge-about-to-lead"].int.val //0' <<< "${data}")
  
  [[ ${about_to_lead} -gt 0 ]] && nodemode="Core" || nodemode="Relay"
  if [[ "${PROTOCOL}" = "Cardano" && ${shelley_transition_epoch} -eq -1 ]]; then # if Shelley transition epoch calc failed during start, try until successful
    getShelleyTransitionEpoch 1 
    kesExpiration
  fi

  header_length=$(( ${#NODE_NAME} + ${#nodemode} + ${#node_version} + ${#node_rev} + 16 ))
  [[ ${header_length} -gt ${width} ]] && header_padding=0 || header_padding=$(( (width - header_length) / 2 ))
  printf "%${header_padding}s >> ${style_values_2}%s${NC} - ${style_info}%s${NC} : ${style_values_1}%s${NC} [${style_values_1}%s${NC}] <<\n" "" "${NODE_NAME}" "${nodemode}" "${node_version}" "${node_rev}"
  ((line++))

  ## Base section ##
  printf "${tdivider}"
  tput cup ${line} $(( width - ${#title} - 3 ))
  printf "${DHL}"
  tput cup $((++line)) 0
  
  printf "${VL} Uptime: $(timeLeft $(( uptimens/1000000000 )))"
  tput cup ${line} $(( width - ${#title} - 3 ))
  printf "${VL} ${style_title}${title} ${VL}\n"
  ((line++))
  printf "${m2divider}"
  tput cup ${line} $(( width - ${#title} - 3 ))
  printf "${UR}"
  printf "%0.s${HL}" $(seq $(( ${#title} + 2 )))
  printf "${LVL}\n"
  ((line++))

  if [[ ${shelley_transition_epoch} -eq -2 ]] || [[ ${shelley_transition_epoch} -ne -1 && ${epochnum} -ge ${shelley_transition_epoch} ]]; then
    epoch_progress=$(echo "(${slot_in_epoch}/${epoch_length})*100" | bc -l)        # in Shelley era or Shelley only TestNet
  else
    epoch_progress=$(echo "(${slot_in_epoch}/${byron_epoch_length})*100" | bc -l)  # in Byron era
  fi
  printf "${VL} Epoch ${style_values_1}%s${NC} [${style_values_1}%2.1f%%${NC}] (node)" "${epochnum}" "${epoch_progress}"
  tput cup ${line} ${second_col}
  [[ "${nwmagic}" == "764824073" ]] && NWNAME="Mainnet" || { [[ "${nwmagic}" = "1097911063" ]] && NWNAME="Testnet" || NWNAME="Custom"; }
  printf "Network    : ${NWNAME}"
  endLine $((line++))
  printf "${VL} ${style_values_1}%s${NC} until epoch boundary (chain)" "$(timeLeft "$(timeUntilNextEpoch)")"
  endLine $((line++))

  epoch_items=$(( $(printf %.0f "${epoch_progress}") / step_size ))
  printf "${VL} ${style_values_1}"
  for i in $(seq 0 $((granularity-1))); do
    [[ $i -lt ${epoch_items} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
  done
  printf "${NC} ${VL}\n"; ((line++))
  
  printf "${VL}"; tput cup $((line++)) ${width}; printf "${VL}\n" # empty line
  
  tip_ref=$(getSlotTipRef)
  tip_diff=$(( tip_ref - slotnum ))
  printf "${VL} Block   : ${style_values_1}%s${NC}" "${blocknum}"
  tput cup ${line} ${second_col}
  printf "Tip (ref)  : ${style_values_1}%s${NC}" "${tip_ref}"
  endLine $((line++))
  printf "${VL} Slot    : ${style_values_1}%s${NC}" "${slot_in_epoch}"
  tput cup ${line} ${second_col}
  printf "Tip (node) : ${style_values_1}%s${NC}" "${slotnum}"
  endLine $((line++))
  printf "${VL} Density : ${style_values_1}%s${NC}%%" "${density}"
  tput cup ${line} ${second_col}
  if [[ ${slotnum} -eq 0 ]]; then
    printf "Status     : ${style_info}starting...${NC}"
  elif [[ "${PROTOCOL}" = "Cardano" && ${shelley_transition_epoch} -eq -1 ]]; then
    printf "Status     : ${style_info}syncing...${NC}"
  elif [[ ${tip_diff} -le $(( slot_interval * 2 )) ]]; then
    printf "Tip (diff) : ${style_status_1}%s${NC}" "${tip_diff} :)"
  elif [[ ${tip_diff} -le $(( slot_interval * 3 )) ]]; then
    printf "Tip (diff) : ${style_status_2}%s${NC}" "${tip_diff} :|"
  else
    printf "Tip (diff) : ${style_status_3}%s${NC}" "${tip_diff} :("
  fi
  endLine $((line++))
  
  echo "${m2divider}"
  ((line++))
  
  printf "${VL} Processed TX     : ${style_values_1}%s${NC}" "${tx_processed}"
  tput cup ${line} $((second_col+7))
  printf "        Out / In"
  endLine $((line++))
  printf "${VL} Mempool TX/Bytes : ${style_values_1}%s${NC} / ${style_values_1}%s${NC}" "${mempool_tx}" "${mempool_bytes}"
  tput el; tput cup ${line} $((second_col+7))
  printf "Peers : ${style_values_1}%s${NC} / ${style_values_1}%s${NC}" "${peers_out}" "${peers_in}"
  endLine $((line++))
  
  ## Core section ##
  if [[ ${nodemode} = "Core" ]]; then
    echo "${mdivider}"
    ((line++))
    
    printf "${VL} KES current/remaining   : ${style_values_1}%s${NC} / " "${kesperiod}"
    if [[ ${remaining_kes_periods} -le 0 ]]; then
      printf "${style_status_4}%s${NC}" "${remaining_kes_periods}"
    elif [[ ${remaining_kes_periods} -le 8 ]]; then
      printf "${style_status_3}%s${NC}" "${remaining_kes_periods}"
    else
      printf "${style_values_1}%s${NC}" "${remaining_kes_periods}"
    fi
    endLine $((line++))
    printf "${VL} KES expiration date     : ${style_values_1}%s${NC}" "${kes_expiration}"
    endLine $((line++))
    
    echo "${m2divider}"
    ((line++))
    
    printf "${VL} %49s" "IsLeader/Adopted/Missed"
    endLine $((line++))
    printf "${VL} Blocks since node start : ${style_values_1}%s${NC} / " "${isleader}"
    if [[ ${adopted} -ne ${isleader} ]]; then
      printf "${style_status_2}%s${NC} / " "${adopted}"
    else
      printf "${style_values_1}%s${NC} / " "${adopted}"
    fi
    if [[ ${didntadopt} -gt 0 ]]; then
      printf "${style_status_3}%s${NC}" "${didntadopt}"
    else
      printf "${style_values_1}%s${NC}" "${didntadopt}"
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
      printf "${VL} Blocks this epoch       : ${style_values_1}%s${NC} / " "${isleader_epoch}"
      if [[ ${adopted_epoch} -ne ${isleader_epoch} ]]; then
        printf "${style_status_2}%s${NC} / " "${adopted_epoch}"
      else
        printf "${style_values_1}%s${NC} / " "${adopted_epoch}"
      fi
      if [[ ${invalid_epoch} -gt 0 ]]; then
        printf "${style_status_3}%s${NC}" "${invalid_epoch}"
      else
        printf "${style_values_1}%s${NC}" "${invalid_epoch}"
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
      printf "${VL} ${style_info}Output peer analysis started... update paused${NC}"
      endLine ${line}
      echo "${bdivider}"
      checkPeers out
      # Save values
      peerCNT0_out=${peerCNT0}; peerCNT1_out=${peerCNT1}; peerCNT2_out=${peerCNT2}; peerCNT3_out=${peerCNT3}; peerCNT4_out=${peerCNT4}
      peerPCT1_out=${peerPCT1}; peerPCT2_out=${peerPCT2}; peerPCT3_out=${peerPCT3}; peerPCT4_out=${peerPCT4}
      peerPCT1items_out=${peerPCT1items}; peerPCT2items_out=${peerPCT2items}; peerPCT3items_out=${peerPCT3items}; peerPCT4items_out=${peerPCT4items}
      peerRTTAVG_out=${peerRTTAVG}; peerCNTUnique_out=${peerCNTUnique}; peerCNTSKIPPED_out=${peerCNTSKIPPED}
      time_out=$(date -u '+%T Z')
    fi
    
    if [[ ${redraw_peers} = "true" ]]; then

      tput cup ${line} 0
      
      printf "${VL}${STANDOUT} OUT ${NC}  RTT : Peers / Percent"
      tput el && tput cup ${line} $(( width - 20 ))
      printf "Updated: ${style_info}%s${NC} ${VL}\n" "${time_out}"
      ((line++))

      printf "${VL}    0-50ms : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_1}" "${peerCNT1_out}" "${peerPCT1_out}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT1items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))

      printf "${VL}  50-100ms : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_2}" "${peerCNT2_out}" "${peerPCT2_out}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT2items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))

      printf "${VL} 100-200ms : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_3}" "${peerCNT3_out}" "${peerPCT3_out}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT3items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))

      printf "${VL}   200ms < : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_4}" "${peerCNT4_out}" "${peerPCT4_out}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT4items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))
        if [[ ${peerRTTAVG_out} -ge 200 ]]; then printf "${VL}   Average : ${style_status_4}%s${NC} ms" "${peerRTTAVG_out}"
      elif [[ ${peerRTTAVG_out} -ge 100 ]]; then printf "${VL}   Average : ${style_status_3}%s${NC} ms" "${peerRTTAVG_out}"
      elif [[ ${peerRTTAVG_out} -ge 50  ]]; then printf "${VL}   Average : ${style_status_2}%s${NC} ms" "${peerRTTAVG_out}"
      elif [[ ${peerRTTAVG_out} -ge 0   ]]; then printf "${VL}   Average : ${style_status_1}%s${NC} ms" "${peerRTTAVG_out}"
      else printf "${VL}   Average : - ms"; fi
      endLine $((line++))
      
      echo "${m3divider}"
      ((line++))
      
      printf "${VL} Unique Peers / Unreachable / Skipped : ${style_values_1}%s${NC} / " "${peerCNTUnique_out}"
      [[ ${peerCNT0_out} -eq 0 ]] && printf "${style_values_1}%s${NC} / " "${peerCNT0_out}" || printf "${style_status_3}%s${NC} / " "${peerCNT0_out}"
      [[ ${peerCNTSKIPPED_out} -eq 0 ]] && printf "${style_values_1}%s${NC}" "${peerCNTSKIPPED_out}" || printf "${style_status_2}%s${NC}" "${peerCNTSKIPPED_out}"
      endLine $((line++))
      
      echo "${m2divider}"
      ((line++))
      
      if [[ ${check_peers} = "true" ]]; then
        printf "${VL} ${style_info}Input peer analysis started... update paused${NC}"
        endLine ${line}
        echo "${bdivider}"
        checkPeers in
        # Save values
        peerCNT0_in=${peerCNT0}; peerCNT1_in=${peerCNT1}; peerCNT2_in=${peerCNT2}; peerCNT3_in=${peerCNT3}; peerCNT4_in=${peerCNT4}
        peerPCT1_in=${peerPCT1}; peerPCT2_in=${peerPCT2}; peerPCT3_in=${peerPCT3}; peerPCT4_in=${peerPCT4}
        peerPCT1items_in=${peerPCT1items}; peerPCT2items_in=${peerPCT2items}; peerPCT3items_in=${peerPCT3items}; peerPCT4items_in=${peerPCT4items}
        peerRTTAVG_in=${peerRTTAVG}; peerCNTUnique_in=${peerCNTUnique}; peerCNTSKIPPED_in=${peerCNTSKIPPED}
        time_in=$(date -u '+%T Z')
      fi
      
      tput cup ${line} 0
      
      printf "${VL}${STANDOUT} In ${NC}   RTT : Peers / Percent"
      tput el && tput cup ${line} $(( width - 20 ))
      printf "Updated: ${style_info}%s${NC} ${VL}\n" "${time_in}"
      ((line++))

      printf "${VL}    0-50ms : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_1}" "${peerCNT1_in}" "${peerPCT1_in}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT1items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))

      printf "${VL}  50-100ms : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_2}" "${peerCNT2_in}" "${peerPCT2_in}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT2items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))

      printf "${VL} 100-200ms : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_3}" "${peerCNT3_in}" "${peerPCT3_in}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT3items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))

      printf "${VL}   200ms < : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_4}" "${peerCNT4_in}" "${peerPCT4_in}"
      tput el && tput cup ${line} ${bar_col_small}
      for i in $(seq 0 $((granularity_small-1))); do
        [[ $i -lt ${peerPCT4items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
      done
      printf "${NC}"
      endLine $((line++))
        if [[ ${peerRTTAVG_in} -ge 200 ]]; then printf "${VL}   Average : ${style_status_4}%s${NC} ms" "${peerRTTAVG_in}"
      elif [[ ${peerRTTAVG_in} -ge 100 ]]; then printf "${VL}   Average : ${style_status_3}%s${NC} ms" "${peerRTTAVG_in}"
      elif [[ ${peerRTTAVG_in} -ge 50  ]]; then printf "${VL}   Average : ${style_status_2}%s${NC} ms" "${peerRTTAVG_in}"
      elif [[ ${peerRTTAVG_in} -ge 0   ]]; then printf "${VL}   Average : ${style_status_1}%s${NC} ms" "${peerRTTAVG_in}"
      else printf "${VL}   Average : - ms"; fi
      endLine $((line++))
      
      echo "${m3divider}"
      ((line++))
      
      printf "${VL} Unique Peers / Unreachable / Skipped : ${style_values_1}%s${NC} / " "${peerCNTUnique_in}"
      [[ ${peerCNT0_in} -eq 0 ]] && printf "${style_values_1}%s${NC} / " "${peerCNT0_in}" || printf "${style_status_3}%s${NC} / " "${peerCNT0_in}"
      [[ ${peerCNTSKIPPED_in} -eq 0 ]] && printf "${style_values_1}%s${NC}" "${peerCNTSKIPPED_in}" || printf "${style_status_2}%s${NC}" "${peerCNTSKIPPED_in}"
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
  printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[p] Peer Analysis${NC}"
  if [[ "${check_peers}" = "true" ]]; then
    check_peers="false"
  fi
  if [[ "${show_peers}" = "true" ]]; then
    printf " | ${style_info}[h] Hide Peers${NC}"
  else
    tput el
  fi
  waitForInput
done
