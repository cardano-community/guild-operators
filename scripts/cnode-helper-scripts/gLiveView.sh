#!/bin/bash
#shellcheck disable=SC2009,SC2034,SC2059,SC2206,SC2086,SC2015
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

NODE_NAME="Cardano Node"                   # Change your node's name prefix here, keep at or below 19 characters!
REFRESH_RATE=2                             # How often (in seconds) to refresh the view (additional time for processing and output may slow it down)
LEGACY_MODE=false                          # (true|false) If enabled unicode box-drawing characters will be replaced by standard ASCII characters
RETRIES=3                                  # How many attempts to connect to running Cardano node before erroring out and quitting
THEME="dark"                               # dark  = suited for terminals with a dark background
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
    style_values_3=${STANDOUT}            # color of selected outgoing/incoming paging
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
    style_values_3=${STANDOUT}            # color of selected outgoing/incoming paging
    style_info=${FG_YELLOW}               # info messages
    style_status_1=${FG_GREEN}            # :)
    style_status_2=${FG_YELLOW}           # :|
    style_status_3=${FG_RED}              # :(
    style_status_4=${FG_MAGENTA}          # :((
  else
    myExit 1 "Please specify a valid THEME name!"
  fi
}

######################################
# Do NOT modify code below           #
######################################

GLV_VERSION=v1.7

PARENT="$(dirname $0)"

# TODO: Rename cntools-offline to master
URL_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators/cntools-offline"
curl -s -m 10 -o "${PARENT}"/env.tmp ${URL_RAW}/scripts/cnode-helper-scripts/env
if [[ -f "${PARENT}"/env ]]; then
  if [[ $(grep "_HOME=" "${PARENT}"/env) =~ ^#?([^[:space:]]+)_HOME ]]; then
    sed -e "s@[C]NODE_HOME=[^ ]*\\(.*\\)@${BASH_REMATCH[1]}_HOME=\"${CNODE_HOME}\"\\1@g" -e "s@[C]NODE_HOME@${BASH_REMATCH[1]}_HOME@g" -i "${PARENT}"/env.tmp
  else
    echo -e "Update failed! Please use prereqs.sh to force an update"
    exit 1
  fi
  TEMPL_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env)
  TEMPL2_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env.tmp)
  if [[ "$(echo ${TEMPL_CMD} | shasum)" != "$(echo ${TEMPL2_CMD} | shasum)" ]]; then
    cp "${PARENT}"/env "${PARENT}/env.bkp_$(date +%s)"
    STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/env)
    printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL2_CMD" > "${PARENT}"/env.tmp
    mv "${PARENT}"/env.tmp "${PARENT}"/env
  fi
else
  mv "${PARENT}"/env.tmp "${PARENT}"/env
fi
rm -f "${PARENT}"/env.tmp

# source common env variables in case it was updated
if ! . "${PARENT}"/env; then exit 1; fi

tput smcup # Save screen
tput civis # Disable cursor
stty -echo # Disable user input

# General exit handler
cleanup() {
  [[ -n $1 ]] && err=$1 || err=$?
  tput rmcup # restore screen
  tput cnorm # restore cursor
  [[ -n ${exit_msg} ]] && echo -e "\n${exit_msg}\n" || echo -e "\nGuild LiveView terminated, cleaning up...\n"
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
if curl -s -m ${CURL_TIMEOUT} -o /tmp/gLiveView.sh "${URL}/gLiveView.sh" 2>/dev/null; then
  GIT_VERSION=$(grep -r ^GLV_VERSION= /tmp/gLiveView.sh | cut -d'=' -f2)
  : "${GIT_VERSION:=v0.0}"
  if [[ "${GLV_VERSION}" != "${GIT_VERSION}" ]]; then
    echo -e "\nA new version of Guild LiveView is available"
    echo "Installed Version : ${GLV_VERSION}"
    echo "Available Version : ${GIT_VERSION}"
    echo -e "\nPress 'u' to update to latest version, or any other key to continue\n"
    read -r -n 1 -s -p "" answer
    if [[ "${answer}" = "u" ]]; then
      if [[ $(grep "_HOME=" "${BASH_SOURCE[0]}") =~ [[:space:]]([^[:space:]]+)_HOME ]]; then
        sed -e "s@[C]NODE_HOME=[^ ]*\\(.*\\)@${BASH_REMATCH[1]}_HOME=\"${CNODE_HOME}\"\\1@g" -e "s@[C]NODE_HOME@${BASH_REMATCH[1]}_HOME@g" -i /tmp/gLiveView.sh
      else
        myExit 1 "${RED}Update failed!${NC}\n\nPlease use prereqs.sh or manually download to update gLiveView"
      fi
      TEMPL_CMD=$(awk '/^# Do NOT modify/,0' /tmp/gLiveView.sh)
      STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${CNODE_HOME}/scripts/gLiveView.sh")
      printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL_CMD" > /tmp/gLiveView.sh
      mv -f "${CNODE_HOME}/scripts/gLiveView.sh" "${CNODE_HOME}/scripts/gLiveView.sh.bkp_$(date +%s)" && \
      cp -f /tmp/gLiveView.sh "${CNODE_HOME}/scripts/gLiveView.sh" && \
      chmod 750 "${CNODE_HOME}/scripts/gLiveView.sh" && \
      myExit 0 "Update applied successfully!\n\nPlease start Guild LiveView again!" || \
      myExit 1 "${RED}Update failed!${NC}\n\nPlease use prereqs.sh or manually download to update gLiveView"
    fi
  fi
else
  echo -e "\nFailed to download gLiveView.sh from GitHub, unable to perform version check!\n"
  read -r -n 1 -s -p "press any key to proceed" answer
fi

#######################################################
# Validate config variables                           #
# Can be overridden in 'User Variables' section above #
#######################################################

[[ ${#NODE_NAME} -gt 19 ]] && myExit 1 "Please keep node name at or below 19 characters in length!"

[[ ! ${REFRESH_RATE} =~ ^[0-9]+$ ]] && myExit 1 "Please set a valid refresh rate number!"

# Style
width=63
second_col=$((width/2 + 3))
NC=$(tput sgr0 && printf "${style_base}") # override default NC in env

setTheme # call function to set theme colors

# Progressbar
if [[ ${LEGACY_MODE} = "true" ]]; then
  char_marked="#"
  char_unmarked="."
else
  char_marked=$(printf "\\u258C")
  char_unmarked=$(printf "\\u2596")
fi
granularity=$((width-3))
granularity_small=$((granularity/2))
bar_col_small=$((width - granularity_small))

# Title
title="Guild LiveView ${GLV_VERSION}"

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
  tdivider=$(printf "${NC}\\u250C" && printf "%0.s\\u2500" $(seq $((width-${#title}-4))) && printf "\\u252C" && printf "%0.s\\u2500" $(seq $((${#title}+2))) && printf "\\u2510")
  mdivider=$(printf "${NC}\\u251C" && printf "%0.s\\u2500" $(seq $((width-1))) && printf "\\u2524")
  m2divider=$(printf "${NC}\\u2502" && printf "%0.s-" $(seq $((width-1))) && printf "\\u2502")
  m3divider=$(printf "${NC}\\u2502" && printf "%0.s- " $(seq $((width/2))) && printf "\\u2502")
  bdivider=$(printf "${NC}\\u2514" && printf "%0.s\\u2500" $(seq $((width-1))) && printf "\\u2518")
fi

#####################################
# Helper functions                  #
#####################################

# Command     : waitForInput
# Description : wait for user keypress to quit, else do nothing if timeout expire
waitForInput() {
  ESC=$(printf "\033")
  if ! read -rsn1 -t ${REFRESH_RATE} key1; then return; fi
  [[ ${key1} = "${ESC}" ]] && read -rsn2 -t 0.3 key2 # read 2 more chars
  [[ ${key1} = "p" && ${show_peers} = "false" ]] && check_peers="true" && clear && return
  [[ ${key1} = "h" && ${show_peers} = "true" ]] && show_peers="false" && clear && return
  [[ ${key1} = "o" && ${show_peers} = "true" ]] && selected_direction="out" && return
  [[ ${key1} = "i" && ${show_peers} = "true" ]] && selected_direction="in" && return
  if [[ ${key2} = "[D" && ${show_peers} = "true" ]]; then # Left arrow
    [[ ${selected_direction} = "out" && ${peerCNT_start_out} -gt 8 ]] && peerCNT_start_out=$((peerCNT_start_out-8)) && clear && return
    [[ ${selected_direction} = "in" && ${peerCNT_start_in} -gt 8 ]] && peerCNT_start_in=$((peerCNT_start_in-8)) && clear && return
  fi
  if [[ ${key2} = "[C" && ${show_peers} = "true" ]]; then # Right arrow
    [[ ${selected_direction} = "out" && ${peerCNTUnique_out} -gt ${peerCNT_out} ]] && peerCNT_start_out=$((peerCNT_start_out+8)) && clear && return
    [[ ${selected_direction} = "in" && ${peerCNTUnique_in} -gt ${peerCNT_in} ]] && peerCNT_start_in=$((peerCNT_start_in+8)) && clear && return
  fi
  [[ ${key1} = "q" ]] && myExit 0 "Guild LiveView stopped!"
  [[ ${key1} = "${ESC}" && ${key2} = "" ]] && myExit 0 "Guild LiveView stopped!"
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
    calc_slot=$(( (byron_epochs * BYRON_EPOCH_LENGTH) + (shelley_epochs * EPOCH_LENGTH) + slot_in_epoch ))
    [[ ${calc_slot} -eq ${slotnum} ]] && break
    ((byron_epochs--))
    ((shelley_epochs++))
  done
  if [[ "${NWMAGIC}" = "764824073" ]]; then
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
    byron_end_time=$(( BYRON_GENESIS_START_SEC + ( shelley_transition_epoch * BYRON_EPOCH_LENGTH * BYRON_SLOT_LENGTH ) ))
    echo $(( shelley_transition_epoch + ( (current_time_sec - byron_end_time) / SLOT_LENGTH / EPOCH_LENGTH ) ))
  else
    echo $(( (current_time_sec - SHELLEY_GENESIS_START_SEC) / SLOT_LENGTH / EPOCH_LENGTH ))
  fi
}

# Command    : getTimeUntilNextEpoch
# Description: Offline calculation of time in seconds until next epoch
timeUntilNextEpoch() {
  current_time_sec=$(date -u +%s)
  if [[ "${PROTOCOL}" = "Cardano" ]]; then
    [[ shelley_transition_epoch -eq -1 ]] && echo 0 && return
    echo $(( (shelley_transition_epoch * BYRON_SLOT_LENGTH * BYRON_EPOCH_LENGTH) + ( ( $(getEpoch) + 1 - shelley_transition_epoch ) * SLOT_LENGTH * EPOCH_LENGTH ) - current_time_sec + BYRON_GENESIS_START_SEC ))
  else
    echo $(( ( ( ( (current_time_sec - SHELLEY_GENESIS_START_SEC) / SLOT_LENGTH / EPOCH_LENGTH ) + 1 ) * SLOT_LENGTH * EPOCH_LENGTH ) - current_time_sec + SHELLEY_GENESIS_START_SEC ))
  fi
}

# Command    : getSlotTipRef
# Description: Get calculated slot number tip
getSlotTipRef() {
  current_time_sec=$(date -u +%s)
  if [[ "${PROTOCOL}" = "Cardano" ]]; then
    [[ shelley_transition_epoch -eq -1 ]] && echo 0 && return
    # Combinator network
    byron_slots=$(( shelley_transition_epoch * BYRON_EPOCH_LENGTH )) # since this point will only be reached once we're in Shelley phase
    byron_end_time=$(( BYRON_GENESIS_START_SEC + ( shelley_transition_epoch * BYRON_EPOCH_LENGTH * BYRON_SLOT_LENGTH ) ))
    if [[ "${current_time_sec}" -lt "${byron_end_time}" ]]; then
      # In Byron phase
      echo $(( ( current_time_sec - BYRON_GENESIS_START_SEC ) / BYRON_SLOT_LENGTH ))
    else
      # In Shelley phase
      echo $(( byron_slots + (( current_time_sec - byron_end_time ) / SLOT_LENGTH ) ))
    fi
  else
    # Shelley Mode only, no Byron slots
    echo $(( ( current_time_sec - SHELLEY_GENESIS_START_SEC ) / SLOT_LENGTH ))
  fi
}

# Command    : kesExpiration [pools remaining KES periods]
# Description: Calculate KES expiration
kesExpiration() {
  current_time_sec=$(date -u +%s)
  tip_ref=$(getSlotTipRef)
  expiration_time_sec=$(( current_time_sec - ( SLOT_LENGTH * (tip_ref % SLOTS_PER_KES_PERIOD) ) + ( SLOT_LENGTH * SLOTS_PER_KES_PERIOD * remaining_kes_periods ) ))
  kes_expiration=$(date '+%F %T Z' --date=@${expiration_time_sec})
}

# Command    : slotInterval
# Description: Calculate expected interval between blocks
slotInterval() {
  [[ $(echo "${DECENTRALISATION} < 0.5" | bc) -eq 1 ]] && local d=0.5 || local d=${DECENTRALISATION}
  echo "(${SLOT_LENGTH} / ${ACTIVE_SLOTS_COEFF} / ${d}) + 0.5" | bc -l | awk '{printf "%.0f\n", $1}'
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
  uniquePeers=(); rttResults=(); rttResultsSorted=""
  direction=$1

  if [[ ${direction} = "out" ]]; then
    netstatPeers=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | awk -v port=":${CNODE_PORT}" '$3 !~ port {print $4}')
  else
    netstatPeers=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | awk -v port=":${CNODE_PORT}" '$3 ~ port {print $4}')
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
    [[ -z ${peerIP} || -z ${peerPORT} ]] && continue

    if checkPEER=$(ping -c 2 -i 0.3 -w 1 "${peerIP}" 2>&1); then # Ping OK, show RTT
      peerRTT=$(echo "${checkPEER}" | tail -n 1 | cut -d/ -f5 | cut -d. -f1)
      ((peerCNT++))
      peerRTTSUM=$((peerRTTSUM + peerRTT))
    elif [[ ${direction} = "in" ]]; then # No need to continue with tcptraceroute for incoming connection as destination port is unknown
      peerRTT=99999
    else # Normal ping is not working, try tcptraceroute to the given port
      checkPEER=$(tcptraceroute -n -S -f 255 -m 255 -q 1 -w 1 "${peerIP}" "${peerPORT}" 2>&1 | tail -n 1)
      if [[ ${checkPEER} = *'[open]'* ]]; then
        peerRTT=$(echo "${checkPEER}" | awk '{print $4}' | cut -d. -f1)
        ((peerCNT++))
        peerRTTSUM=$((peerRTTSUM + peerRTT))
      else # Nope, no response
        peerRTT=99999
      fi
    fi

    # Update counters
      if [[ ${peerRTT} -lt 50    ]]; then ((peerCNT1++))
    elif [[ ${peerRTT} -lt 100   ]]; then ((peerCNT2++))
    elif [[ ${peerRTT} -lt 200   ]]; then ((peerCNT3++))
    elif [[ ${peerRTT} -lt 99999 ]]; then ((peerCNT4++))
    else ((peerCNT0++)); fi
    rttResults+=("${peerRTT}:${peerIP}:${peerPORT} ")
  done
  [[ ${#rttResults[@]} ]] && rttResultsSorted=$(printf '%s\n' "${rttResults[@]}" | sort -n)
  [[ ${peerCNT} -gt 0 ]]  && peerRTTAVG=$((peerRTTSUM / peerCNT))
  peerCNTSKIPPED=$(( peerCNTABS - peerCNTUnique ))
  
  peerMAX=0
  if [[ ${peerCNT} -gt 0 ]]; then
    peerPCT1=$(echo "scale=4;(${peerCNT1}/${peerCNT})*100" | bc -l)
    peerPCT1items=$(printf %.0f "$(echo "scale=4;${peerPCT1}*${granularity_small}/100" | bc -l)")
    peerPCT2=$(echo "scale=4;(${peerCNT2}/${peerCNT})*100" | bc -l)
    peerPCT2items=$(printf %.0f "$(echo "scale=4;${peerPCT2}*${granularity_small}/100" | bc -l)")
    peerPCT3=$(echo "scale=4;(${peerCNT3}/${peerCNT})*100" | bc -l)
    peerPCT3items=$(printf %.0f "$(echo "scale=4;${peerPCT3}*${granularity_small}/100" | bc -l)")
    peerPCT4=$(echo "scale=4;(${peerCNT4}/${peerCNT})*100" | bc -l)
    peerPCT4items=$(printf %.0f "$(echo "scale=4;${peerPCT4}*${granularity_small}/100" | bc -l)")
  fi
}

#####################################
# Static variables/calculations     #
#####################################
check_peers="false"
show_peers="false"
selected_direction="out"
data=$(curl -s -m ${EKG_TIMEOUT} -H 'Accept: application/json' "http://${EKG_HOST}:${EKG_PORT}/" 2>/dev/null)
epochnum=$(jq '.cardano.node.ChainDB.metrics.epoch.int.val //0' <<< "${data}")
curr_epoch=${epochnum}
slot_in_epoch=$(jq '.cardano.node.ChainDB.metrics.slotInEpoch.int.val //0' <<< "${data}")
slotnum=$(jq '.cardano.node.ChainDB.metrics.slotNum.int.val //0' <<< "${data}")
remaining_kes_periods=$(jq '.cardano.node.Forge.metrics.remainingKESPeriods.int.val //0' <<< "${data}")
[[ "${PROTOCOL}" = "Cardano" ]] && getShelleyTransitionEpoch || shelley_transition_epoch=-2
#####################################

clear
tlines=$(tput lines) # set initial terminal lines
tcols=$(tput cols)   # set initial terminal columns
printf "${NC}"       # reset and set default color
fail_count=0

#####################################
# MAIN LOOP                         #
#####################################
while true; do
  tlines=$(tput lines) # update terminal lines
  tcols=$(tput cols)   # update terminal columns
  [[ ${width} -ge $((tcols)) || ${line} -ge $((tlines)) ]] && clear
  while [[ ${width} -ge $((tcols)) ]]; do
    tput cup 1 1
    printf "${style_status_3}Terminal width too small!${NC}"
    tput cup 3 1
    printf "Please increase by ${style_info}$(( width - tcols + 1 ))${NC} columns"
    tput cup 5 1
    printf "${style_info}[esc/q] Quit${NC}"
    waitForInput
    tlines=$(tput lines) # update terminal lines
    tcols=$(tput cols)   # update terminal columns
  done
  while [[ ${line} -ge $((tlines)) ]]; do
    tput cup 1 1
    printf "${style_status_3}Terminal height too small!${NC}"
    tput cup 3 1
    printf "Please increase by ${style_info}$(( line - tlines + 1 ))${NC} lines"
    tput cup 5 1
    printf "${style_info}[esc/q] Quit${NC}"
    waitForInput
    tlines=$(tput lines) # update terminal lines
    tcols=$(tput cols)   # update terminal columns
  done
  
  line=0; tput cup 0 0 # reset position

  # Gather some data
  version=$("$(command -v cardano-node)" version)
  node_version=$(grep "cardano-node" <<< "${version}" | cut -d ' ' -f2)
  node_rev=$(grep "git rev" <<< "${version}" | cut -d ' ' -f3 | cut -c1-8)
  data=$(curl -s -m ${EKG_TIMEOUT} -H 'Accept: application/json' "http://${EKG_HOST}:${EKG_PORT}/" 2>/dev/null)
  uptimens=$(jq '.cardano.node.metrics.upTime.ns.val //0' <<< "${data}")
  [[ ${fail_count} -eq ${RETRIES} ]] && myExit 1 "${style_status_3}COULD NOT CONNECT TO A RUNNING INSTANCE, ${RETRIES} FAILED ATTEMPTS IN A ROW!${NC}"
  if [[ ${uptimens} -le 0 ]]; then
    ((fail_count++))
    clear && tput cup 1 1
    printf "${style_status_3}Connection to node lost, retrying (${fail_count}/${RETRIES})!${NC}"
    waitForInput && continue
  else
    fail_count=0
  fi
  if [[ ${show_peers} = "false" ]]; then
    peers_in=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | awk -v port=":${CNODE_PORT}" '$3 ~ port {print}' | wc -l)
    peers_out=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | awk -v port=":${CNODE_PORT}" '$3 !~ port {print}' | wc -l)
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
    if [[ ${about_to_lead} -gt 0 ]]; then
      [[ ${nodemode} != "Core" ]] && clear && nodemode="Core"
    else
      [[ ${nodemode} != "Relay" ]] && clear && nodemode="Relay"
    fi
    if [[ "${PROTOCOL}" = "Cardano" && ${shelley_transition_epoch} -eq -1 ]]; then # if Shelley transition epoch calc failed during start, try until successful
      getShelleyTransitionEpoch 1
      kes_expiration="---"
    else
      kesExpiration
    fi
    if [[ ${curr_epoch} -ne ${epochnum} ]]; then # only update on new epoch to save on processing
      curr_epoch=${epochnum}
      PROT_PARAMS="$(${CCLI} shelley query protocol-parameters ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} 2>/dev/null)"
      if [[ -n "${PROT_PARAMS}" ]] && ! DECENTRALISATION=$(jq -re .decentralisationParam <<< ${PROT_PARAMS} 2>/dev/null); then DECENTRALISATION=0.5; fi
    fi
  fi

  header_length=$(( ${#NODE_NAME} + ${#nodemode} + ${#node_version} + ${#node_rev} + ${#NETWORK_NAME} + 19 ))
  [[ ${header_length} -gt ${width} ]] && header_padding=0 || header_padding=$(( (width - header_length) / 2 ))
  printf "%${header_padding}s > ${style_values_2}%s${NC} - ${style_info}(%s - %s)${NC} : ${style_values_1}%s${NC} [${style_values_1}%s${NC}] < \n" "" "${NODE_NAME}" "${nodemode}" "${NETWORK_NAME}" "${node_version}" "${node_rev}" && ((line++))

  ## main section ##
  printf "${tdivider}\n" && ((line++))
  printf "${VL} Uptime: ${style_values_1}%s${NC}" "$(timeLeft $(( uptimens/1000000000 )))"
  tput cup ${line} $(( width - ${#title} - 3 ))
  printf "${VL} ${style_title}${title} ${VL}\n" && ((line++))
  printf "${m2divider}"
  tput cup ${line} $(( width - ${#title} - 3 ))
  printf "${UR}"
  printf "%0.s${HL}" $(seq $(( ${#title} + 2 )))
  printf "${LVL}\n" && ((line++))
  
  if [[ ${check_peers} = "true" ]]; then
    tput ed
    printf "${VL} ${style_info}%-$((width-3))s${NC} ${VL}\n" "Output peer analysis started... please wait!"
    echo "${bdivider}"
    checkPeers out
    # Save values
    peerCNT0_out=${peerCNT0}; peerCNT1_out=${peerCNT1}; peerCNT2_out=${peerCNT2}; peerCNT3_out=${peerCNT3}; peerCNT4_out=${peerCNT4}
    peerPCT1_out=${peerPCT1}; peerPCT2_out=${peerPCT2}; peerPCT3_out=${peerPCT3}; peerPCT4_out=${peerPCT4}
    peerPCT1items_out=${peerPCT1items}; peerPCT2items_out=${peerPCT2items}; peerPCT3items_out=${peerPCT3items}; peerPCT4items_out=${peerPCT4items}
    peerRTTAVG_out=${peerRTTAVG}; peerCNTUnique_out=${peerCNTUnique}; peerCNTSKIPPED_out=${peerCNTSKIPPED}; rttResultsSorted_out=${rttResultsSorted}
    peerCNT_start_out=1
    tput cup ${line} 0
    tput ed
    printf "${VL} ${style_info}%-$((width-3))s${NC} ${VL}\n" "Output peer analysis done!" && ((line++))
      
    echo "${m2divider}" && ((line++))

    printf "${VL} ${style_info}%-$((width-3))s${NC} ${VL}\n" "Input peer analysis started... please wait!" && ((line++))
    echo "${bdivider}" && ((line++))
    checkPeers in
    # Save values
    peerCNT0_in=${peerCNT0}; peerCNT1_in=${peerCNT1}; peerCNT2_in=${peerCNT2}; peerCNT3_in=${peerCNT3}; peerCNT4_in=${peerCNT4}
    peerPCT1_in=${peerPCT1}; peerPCT2_in=${peerPCT2}; peerPCT3_in=${peerPCT3}; peerPCT4_in=${peerPCT4}
    peerPCT1items_in=${peerPCT1items}; peerPCT2items_in=${peerPCT2items}; peerPCT3items_in=${peerPCT3items}; peerPCT4items_in=${peerPCT4items}
    peerRTTAVG_in=${peerRTTAVG}; peerCNTUnique_in=${peerCNTUnique}; peerCNTSKIPPED_in=${peerCNTSKIPPED}; rttResultsSorted_in=${rttResultsSorted}
    peerCNT_start_in=1
  elif [[ ${show_peers} = "true" ]]; then
    printf "${VL}${STANDOUT} OUT ${NC}  RTT : Peers / Percent"
    tput cup ${line} ${width}
    printf "${VL}\n" && ((line++))

    printf "${VL}    0-50ms : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_1}" "${peerCNT1_out}" "${peerPCT1_out}"
    tput cup ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT1items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    printf "${NC}${VL}\n" && ((line++))

    printf "${VL}  50-100ms : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_2}" "${peerCNT2_out}" "${peerPCT2_out}"
    tput cup ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT2items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    printf "${NC}${VL}\n" && ((line++))

    printf "${VL} 100-200ms : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_3}" "${peerCNT3_out}" "${peerPCT3_out}"
    tput cup ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT3items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    printf "${NC}${VL}\n" && ((line++))

    printf "${VL}   200ms < : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_4}" "${peerCNT4_out}" "${peerPCT4_out}"
    tput cup ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT4items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    printf "${NC}${VL}\n" && ((line++))
      if [[ ${peerRTTAVG_out} -ge 200 ]]; then printf "${VL}   Average : ${style_status_4}%s${NC} ms %$((width-18-${#peerRTTAVG_out}))s${VL}\n" "${peerRTTAVG_out}"
    elif [[ ${peerRTTAVG_out} -ge 100 ]]; then printf "${VL}   Average : ${style_status_3}%s${NC} ms %$((width-18-${#peerRTTAVG_out}))s${VL}\n" "${peerRTTAVG_out}"
    elif [[ ${peerRTTAVG_out} -ge 50  ]]; then printf "${VL}   Average : ${style_status_2}%s${NC} ms %$((width-18-${#peerRTTAVG_out}))s${VL}\n" "${peerRTTAVG_out}"
    elif [[ ${peerRTTAVG_out} -ge 0   ]]; then printf "${VL}   Average : ${style_status_1}%s${NC} ms %$((width-18-${#peerRTTAVG_out}))s${VL}\n" "${peerRTTAVG_out}"
    else printf "${VL}   Average : --- ms %$((width-21))s${VL}\n"; fi
    ((line++))
    
    echo "${m3divider}" && ((line++))
    
    printf "${VL} Total / Unique / Unreachable / Skipped : ${style_values_1}%s${NC} / ${style_values_1}%s${NC} / " "${peers_out}" "${peerCNTUnique_out}"
    [[ ${peerCNT0_out} -eq 0 ]] && printf "${style_values_1}%s${NC} / " "${peerCNT0_out}" || printf "${style_status_3}%s${NC} / " "${peerCNT0_out}"
    [[ ${peerCNTSKIPPED_out} -eq 0 ]] && printf "${style_values_1}%s${NC}" "${peerCNTSKIPPED_out}" || printf "${style_status_2}%s${NC}" "${peerCNTSKIPPED_out}"
    tput cup ${line} ${width}
    printf "${VL}\n" && ((line++))

    if [[ -n ${rttResultsSorted_out} ]]; then
      echo "${m3divider}" && ((line++))
      
      printf "${VL}${style_info}   # : %20s   : RTT (ms)${NC}\n" "REMOTE PEER"
      header_line=$((line++))
      
      peerCNT_out=0
      for peer in ${rttResultsSorted_out}; do
        ((peerCNT_out++))
        [[ ${peerCNT_out} -lt ${peerCNT_start_out} ]] && continue
        peerRTT=$(echo ${peer} | cut -d: -f1)
        peerIP=$(echo ${peer} | cut -d: -f2)
        peerPORT=$(echo ${peer} | cut -d: -f3)
          if [[ ${peerRTT} -lt 50    ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_1}%-5s${NC} %$((width-39))s${VL}\n" ${peerCNT_out} ${peerIP} ${peerPORT} ${peerRTT}
        elif [[ ${peerRTT} -lt 100   ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_2}%-5s${NC} %$((width-39))s${VL}\n" ${peerCNT_out} ${peerIP} ${peerPORT} ${peerRTT}
        elif [[ ${peerRTT} -lt 200   ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_3}%-5s${NC} %$((width-39))s${VL}\n" ${peerCNT_out} ${peerIP} ${peerPORT} ${peerRTT}
        elif [[ ${peerRTT} -lt 99999 ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_4}%-5s${NC} %$((width-39))s${VL}\n" ${peerCNT_out} ${peerIP} ${peerPORT} ${peerRTT}
        else printf "${VL} %3s : %15s:%-6s : --- %$((width-37))s${VL}\n" ${peerCNT_out} ${peerIP} ${peerPORT}; fi
        ((line++))
        [[ ${peerCNT_out} -eq $((peerCNT_start_out+7)) ]] && break
      done
      
      [[ ${peerCNT_start_out} -gt 1 ]] && nav_str="< " || nav_str=""
      nav_str+="[${peerCNT_start_out}-${peerCNT_out}]"
      [[ ${peerCNTUnique_out} -gt ${peerCNT_out} ]] && nav_str+=" >"
      tput cup ${header_line} $((width-${#nav_str}-3))
      [[ ${selected_direction} = "out" ]] && printf "${style_values_3} %s ${NC} ${VL}\n" "${nav_str}" || printf "  %s ${VL}\n" "${nav_str}"
      tput cup ${line} 0
    fi
    
    echo "${mdivider}" && ((line++))
    
    printf "${VL}${STANDOUT} In ${NC}   RTT : Peers / Percent"
    tput cup ${line} ${width}
    printf "${VL}\n" && ((line++))

    printf "${VL}    0-50ms : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_1}" "${peerCNT1_in}" "${peerPCT1_in}"
    tput cup ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT1items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    printf "${NC}${VL}\n" && ((line++))

    printf "${VL}  50-100ms : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_2}" "${peerCNT2_in}" "${peerPCT2_in}"
    tput cup ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT2items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    printf "${NC}${VL}\n" && ((line++))

    printf "${VL} 100-200ms : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_3}" "${peerCNT3_in}" "${peerPCT3_in}"
    tput cup ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT3items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    printf "${NC}${VL}\n" && ((line++))

    printf "${VL}   200ms < : ${style_values_1}%5s${NC} / ${style_values_1}%.f${NC}%% ${style_status_4}" "${peerCNT4_in}" "${peerPCT4_in}"
    tput cup ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT4items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    printf "${NC}${VL}\n" && ((line++))
      if [[ ${peerRTTAVG_in} -ge 200 ]]; then printf "${VL}   Average : ${style_status_4}%s${NC} ms %$((width-18-${#peerRTTAVG_in}))s${VL}\n" "${peerRTTAVG_in}"
    elif [[ ${peerRTTAVG_in} -ge 100 ]]; then printf "${VL}   Average : ${style_status_3}%s${NC} ms %$((width-18-${#peerRTTAVG_in}))s${VL}\n" "${peerRTTAVG_in}"
    elif [[ ${peerRTTAVG_in} -ge 50  ]]; then printf "${VL}   Average : ${style_status_2}%s${NC} ms %$((width-18-${#peerRTTAVG_in}))s${VL}\n" "${peerRTTAVG_in}"
    elif [[ ${peerRTTAVG_in} -ge 0   ]]; then printf "${VL}   Average : ${style_status_1}%s${NC} ms %$((width-18-${#peerRTTAVG_in}))s${VL}\n" "${peerRTTAVG_in}"
    else printf "${VL}   Average : - ms %$((width-21))s${VL}\n"; fi
    ((line++))
    
    echo "${m3divider}" && ((line++))
    
    printf "${VL} Total / Unique / Unreachable / Skipped : ${style_values_1}%s${NC} / ${style_values_1}%s${NC} / " "${peers_in}" "${peerCNTUnique_in}"
    [[ ${peerCNT0_in} -eq 0 ]] && printf "${style_values_1}%s${NC} / " "${peerCNT0_in}" || printf "${style_status_3}%s${NC} / " "${peerCNT0_in}"
    [[ ${peerCNTSKIPPED_in} -eq 0 ]] && printf "${style_values_1}%s${NC}" "${peerCNTSKIPPED_in}" || printf "${style_status_2}%s${NC}" "${peerCNTSKIPPED_in}"
    tput cup ${line} ${width}
    printf "${VL}\n" && ((line++))
    
    if [[ -n ${rttResultsSorted_in} ]]; then
      echo "${m3divider}" && ((line++))
      
      printf "${VL}${style_info}   # : %20s   : RTT (ms)${NC}\n" "REMOTE PEER"
      header_line=$((line++))
      
      peerCNT_in=0
      for peer in ${rttResultsSorted_in}; do
        ((peerCNT_in++))
        [[ ${peerCNT_in} -lt ${peerCNT_start_in} ]] && continue
        peerRTT=$(echo ${peer} | cut -d: -f1)
        peerIP=$(echo ${peer} | cut -d: -f2)
        peerPORT=$(echo ${peer} | cut -d: -f3)
          if [[ ${peerRTT} -lt 50    ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_1}%-5s${NC} %$((width-39))s${VL}\n" ${peerCNT_in} ${peerIP} ${peerPORT} ${peerRTT}
        elif [[ ${peerRTT} -lt 100   ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_2}%-5s${NC} %$((width-39))s${VL}\n" ${peerCNT_in} ${peerIP} ${peerPORT} ${peerRTT}
        elif [[ ${peerRTT} -lt 200   ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_3}%-5s${NC} %$((width-39))s${VL}\n" ${peerCNT_in} ${peerIP} ${peerPORT} ${peerRTT}
        elif [[ ${peerRTT} -lt 99999 ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_4}%-5s${NC} %$((width-39))s${VL}\n" ${peerCNT_in} ${peerIP} ${peerPORT} ${peerRTT}
        else printf "${VL} %3s : %15s:%-6s : --- %$((width-37))s${VL}\n" ${peerCNT_in} ${peerIP} ${peerPORT}; fi
        ((line++))
        [[ ${peerCNT_in} -eq $((peerCNT_start_in+7)) ]] && break
      done
      
      [[ ${peerCNT_start_in} -gt 1 ]] && nav_str="< " || nav_str=""
      nav_str+="[${peerCNT_start_in}-${peerCNT_in}]"
      [[ ${peerCNTUnique_in} -gt ${peerCNT_in} ]] && nav_str+=" >"
      tput cup ${header_line} $((width-${#nav_str}-3))
      [[ ${selected_direction} = "in" ]] && printf "${style_values_3} %s ${NC} ${VL}\n" "${nav_str}" || printf "  %s ${VL}\n" "${nav_str}"
      tput cup ${line} 0
    fi
  else
    if [[ ${shelley_transition_epoch} -eq -2 ]] || [[ ${shelley_transition_epoch} -ne -1 && ${epochnum} -ge ${shelley_transition_epoch} ]]; then
      epoch_progress=$(echo "(${slot_in_epoch}/${EPOCH_LENGTH})*100" | bc -l)        # in Shelley era or Shelley only TestNet
    else
      epoch_progress=$(echo "(${slot_in_epoch}/${BYRON_EPOCH_LENGTH})*100" | bc -l)  # in Byron era
    fi
    epoch_progress_1dec=$(printf "%2.1f" "${epoch_progress}")
    printf "${VL} Epoch ${style_values_1}%s${NC} [${style_values_1}%s%%${NC}] (node)%$((width-19-${#epochnum}-${#epoch_progress_1dec}))s${VL}\n" "${epochnum}" "${epoch_progress_1dec}" && ((line++))
    epoch_time_left=$(timeLeft "$(timeUntilNextEpoch)")
    printf "${VL} ${style_values_1}%s${NC} until epoch boundary (chain)%$((width-31-${#epoch_time_left}))s${VL}\n" "${epoch_time_left}" && ((line++))

    epoch_items=$(( $(printf %.0f "${epoch_progress}") * granularity / 100 ))
    printf "${VL} ${style_values_1}"
    for i in $(seq 0 $((granularity-1))); do
      [[ $i -lt ${epoch_items} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    printf "${NC} ${VL}\n"; ((line++))
    
    printf "${VL}"; tput cup $((line++)) ${width}; printf "${VL}\n" # empty line
    
    tip_ref=$(getSlotTipRef)
    tip_diff=$(( tip_ref - slotnum ))
    sec_col_value_size=$((width-second_col-13))
    printf "${VL} Block   : ${style_values_1}%s${NC}" "${blocknum}"
    tput cup ${line} ${second_col}
    printf "Tip (ref)  : ${style_values_1}%-${sec_col_value_size}s${NC}${VL}\n" "${tip_ref}" && ((line++))
    printf "${VL} Slot    : ${style_values_1}%s${NC}" "${slot_in_epoch}"
    tput cup ${line} ${second_col}
    printf "Tip (node) : ${style_values_1}%-${sec_col_value_size}s${NC}${VL}\n" "${slotnum}" && ((line++))
    printf "${VL} Density : ${style_values_1}%s${NC}" "${density}"
    tput cup ${line} ${second_col}
    if [[ ${slotnum} -eq 0 ]]; then
      printf "Status     : ${style_info}%-${sec_col_value_size}s${NC}${VL}\n" "starting..."
    elif [[ "${PROTOCOL}" = "Cardano" && ${shelley_transition_epoch} -eq -1 ]]; then
      printf "Status     : ${style_info}%-${sec_col_value_size}s${NC}${VL}\n" "syncing..."
    elif [[ ${tip_diff} -le $(slotInterval) ]]; then
      printf "Tip (diff) : ${style_status_1}%-${sec_col_value_size}s${NC}${VL}\n" "${tip_diff} :)"
    elif [[ ${tip_diff} -le $(( $(slotInterval) * 2 )) ]]; then
      printf "Tip (diff) : ${style_status_2}%-${sec_col_value_size}s${NC}${VL}\n" "${tip_diff} :|"
    else
      printf "Tip (diff) : ${style_status_3}%-${sec_col_value_size}s${NC}${VL}\n" "${tip_diff} :("
    fi
    ((line++))
    
    echo "${m2divider}" && ((line++))
    
    printf "${VL} Processed TX     : ${style_values_1}%s${NC}" "${tx_processed}"
    tput cup ${line} $((second_col))
    printf "%-$((width-second_col))s${NC}${VL}\n" "        Out / In" && ((line++))
    printf "${VL} Mempool TX/Bytes : ${style_values_1}%s${NC} / ${style_values_1}%s${NC}%$((second_col-24-${#mempool_tx}-${#mempool_bytes}))s" "${mempool_tx}" "${mempool_bytes}"
    printf "Peers : ${style_values_1}%3s${NC}   ${style_values_1}%-5s${NC}%$((width-second_col-19))s${VL}\n" "${peers_out}" "${peers_in}" && ((line++))
    
    ## Core section ##
    if [[ ${nodemode} = "Core" ]]; then
      echo "${mdivider}" && ((line++))
      
      printf "${VL} KES current/remaining"
      tput cup ${line} $((second_col-2))
      printf ": ${style_values_1}%s${NC} / " "${kesperiod}"
      if [[ ${remaining_kes_periods} -le 0 ]]; then
        printf "${style_status_4}%s${NC}" "${remaining_kes_periods}"
      elif [[ ${remaining_kes_periods} -le 8 ]]; then
        printf "${style_status_3}%s${NC}" "${remaining_kes_periods}"
      else
        printf "${style_values_1}%s${NC}" "${remaining_kes_periods}"
      fi
      printf "%$((width-second_col-3-${#kesperiod}-${#remaining_kes_periods}))s${VL}\n" && ((line++))
      printf "${VL} KES expiration date"
      tput cup ${line} $((second_col-2))
      printf ": ${style_values_1}%-$((width-second_col))s${NC}${VL}\n" "${kes_expiration}" && ((line++))
      
      echo "${m2divider}" && ((line++))
      
      printf "${VL}"
      tput cup ${line} ${second_col}
      printf "%-$((width-second_col))s${NC}${VL}\n" "IsLeader / Adopted / Missed" && ((line++))
      printf "${VL} Blocks since node start"
      tput cup ${line} $((second_col-2))
      printf ": ${style_values_1}%-11s${NC}" "${isleader}"
      if [[ ${adopted} -ne ${isleader} ]]; then
        printf "${style_status_2}%-10s${NC}" "${adopted}"
      else
        printf "${style_values_1}%-10s${NC}" "${adopted}"
      fi
      if [[ ${didntadopt} -gt 0 ]]; then
        printf "${style_status_3}%-9s${NC}" "${didntadopt}"
      else
        printf "${style_values_1}%-9s${NC}" "${didntadopt}"
      fi
      tput cup ${line} ${width}
      printf "${VL}\n" && ((line++))
      
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
        printf "${VL} Blocks this epoch"
        tput cup ${line} $((second_col-2))
        printf ": ${style_values_1}%-11s${NC}" "${isleader_epoch}"
        if [[ ${adopted_epoch} -ne ${isleader_epoch} ]]; then
          printf "${style_status_2}%-10s${NC}" "${adopted_epoch}"
        else
          printf "${style_values_1}%-10s${NC}" "${adopted_epoch}"
        fi
        if [[ ${invalid_epoch} -gt 0 ]]; then
          printf "${style_status_3}%-9s${NC}" "${invalid_epoch}"
        else
          printf "${style_values_1}%-9s${NC}" "${invalid_epoch}"
        fi
        tput cup ${line} ${width}
        printf "${VL}\n" && ((line++))
      fi
    fi
  fi
  
  [[ ${check_peers} = "true" ]] && check_peers=false && show_peers=true && clear && continue
  
  echo "${bdivider}" && ((line++))
  [[ ${show_peers} = "true" ]] && printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[h] Home${NC} | Select Peer List : ${style_info}[o] Out${NC} - ${style_info}[i] In${NC}\n%27s%s" "" "Use left/right arrow key to navigate" || \
                                  printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[p] Peer Analysis${NC}"
  tput el
  waitForInput
done
