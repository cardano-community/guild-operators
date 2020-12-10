#!/bin/bash
#shellcheck disable=SC2009,SC2034,SC2059,SC2206,SC2086,SC2015
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

NODE_NAME="Cardano Node"                   # Change your node's name prefix here, keep at or below 19 characters!
REFRESH_RATE=5                             # How often (in seconds) to refresh the view (additional time for processing and output may slow it down)
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

GLV_VERSION=v1.15

PARENT="$(dirname $0)"
[[ -f "${PARENT}"/.env_branch ]] && BRANCH="$(cat ${PARENT}/.env_branch)" || BRANCH="master"

# For those using auto update from version gLiveView 1.9 where RETRIES isnt set in user-defined variables
[[ -z "${RETRIES}" ]]  && RETRIES=3

usage() {
  cat <<EOF
Usage: $(basename "$0") [-l] [-p] [-b <branch name>]
Guild LiveView - An alternative cardano-node LiveView

-l    Activate legacy mode - standard ASCII characters instead of box-drawing characters
-p    Disable default CNCLI ping and revert to legacy tcptraceroute if available, else use regular ICMP ping.
-b    Use alternate branch to check for updates - only for testing/development (Default: Master)  
EOF
  exit 1
}

while getopts :lpb: opt; do
  case ${opt} in
    l ) LEGACY_MODE="true" ;;
    p ) DISABLE_CNCLI="true" ;;
    b ) BRANCH=${OPTARG}; echo "${BRANCH}" > "${PARENT}"/.env_branch ;;
    \? ) usage ;;
    esac
done
shift $((OPTIND -1))

URL="https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}/scripts/cnode-helper-scripts"
if curl -s -m 10 -o "${PARENT}"/env.tmp ${URL}/env; then
  if [[ -f "${PARENT}"/env ]]; then
    if [[ $(grep "_HOME=" "${PARENT}"/env) =~ ^#?([^[:space:]]+)_HOME ]]; then
      vname=$(tr '[:upper:]' '[:lower:]' <<< ${BASH_REMATCH[1]})
      sed -e "s@/opt/cardano/[c]node@/opt/cardano/${vname}@g" -e "s@[C]NODE_HOME@${BASH_REMATCH[1]}_HOME@g" -i "${PARENT}"/env.tmp
    else
      echo -e "Update failed! Please use prereqs.sh to force an update or manually download $(basename $0) + env from GitHub"
      exit 1
    fi
    TEMPL_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env)
    TEMPL2_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env.tmp)
    if [[ "$(echo ${TEMPL_CMD} | sha256sum)" != "$(echo ${TEMPL2_CMD} | sha256sum)" ]]; then
      cp "${PARENT}"/env "${PARENT}/env_bkp$(date +%s)"
      STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/env)
      printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL2_CMD" > "${PARENT}"/env.tmp
      mv "${PARENT}"/env.tmp "${PARENT}"/env
    fi
  else
    mv "${PARENT}"/env.tmp "${PARENT}"/env
  fi
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

if command -v "ss" &>/dev/null; then 
  use_lsof='N'
elif command -v "lsof" &>/dev/null; then 
  use_lsof='Y'
else
  myExit 1 "'ss' and fallback 'lsof' commands missing, please install using latest prereqs.sh script or with your packet manager of choice.\nhttps://command-not-found.com/ss can be used to check package name to install."
fi

if ! command -v "tcptraceroute" &>/dev/null; then
  myExit 1 "'tcptraceroute' command missing, please install using latest prereqs.sh script or with your packet manager of choice.\nhttps://command-not-found.com/tcptraceroute can be used to check package name to install."
fi

#######################################################
# Version Check                                       #
#######################################################
clear
echo "Guild LiveView version check..."
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
      TEMPL_CMD=$(awk '/^# Do NOT modify/,0' /tmp/gLiveView.sh)
      STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}/gLiveView.sh")
      printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL_CMD" > /tmp/gLiveView.sh
      mv -f "${PARENT}/gLiveView.sh" "${PARENT}/gLiveView.sh_bkp$(date +%s)" && \
      cp -f /tmp/gLiveView.sh "${PARENT}/gLiveView.sh" && \
      chmod 750 "${PARENT}/gLiveView.sh" && \
      myExit 0 "Update applied successfully!\n\nPlease start Guild LiveView again!" || \
      myExit 1 "${FG_RED}Update failed!${NC}\n\nPlease use prereqs.sh or manually download to update gLiveView"
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
  blank_line=$(printf "${NC}|%$((width-1))s|" "")
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
  blank_line=$(printf "${NC}\\u2502%$((width-1))s\\u2502" "")
fi

#####################################
# Helper functions                  #
#####################################

# Command     : waitForInput [submenu]
# Description : wait for user keypress to quit, else do nothing if timeout expire
waitForInput() {
  ESC=$(printf "\033")
  if ! read -rsn1 -t ${REFRESH_RATE} key1; then return; fi
  [[ ${key1} = "${ESC}" ]] && read -rsn2 -t 0.3 key2 # read 2 more chars
  [[ ${key1} = "q" ]] && myExit 0 "Guild LiveView stopped!"
  [[ ${key1} = "${ESC}" && ${key2} = "" ]] && myExit 0 "Guild LiveView stopped!"
  if [[ $# -eq 0 ]]; then
    [[ ${key1} = "p" ]] && check_peers="true" && clear && return
    [[ ${key1} = "i" ]] && show_home_info="true" && clear && return
  elif [[ $1 = "homeInfo" ]]; then
    [[ ${key1} = "h" ]] && show_home_info="false" && clear && return
  elif [[ $1 = "peersInfo" ]]; then
    [[ ${key1} = "b" ]] && show_peers_info="false" && clear && return
  elif [[ $1 = "peers" ]]; then
    [[ ${key1} = "h" ]] && show_peers="false" && clear && return
    [[ ${key1} = "i" ]] && show_peers_info="true" && clear && return
    [[ ${key2} = "[A" ]] && selected_direction="out" && return # Up arrow
    [[ ${key2} = "[B" ]] && selected_direction="in" && return # Down arrow
    if [[ ${key2} = "[C" && ${show_peers} = "true" ]]; then # Right arrow
      [[ ${selected_direction} = "out" && ${peerCNT_out} -gt ${peerNbr_out} ]] && peerNbr_start_out=$((peerNbr_start_out+8)) && clear && return
      [[ ${selected_direction} = "in" && ${peerCNT_in} -gt ${peerNbr_in} ]] && peerNbr_start_in=$((peerNbr_start_in+8)) && clear && return
    fi
    if [[ ${key2} = "[D" && ${show_peers} = "true" ]]; then # Left arrow
      [[ ${selected_direction} = "out" && ${peerNbr_start_out} -gt 8 ]] && peerNbr_start_out=$((peerNbr_start_out-8)) && clear && return
      [[ ${selected_direction} = "in" && ${peerNbr_start_in} -gt 8 ]] && peerNbr_start_in=$((peerNbr_start_in-8)) && clear && return
    fi
  fi
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
  peerRTTSUM=0; peerRTTAVG=0
  rttResults=(); rttResultsSorted=""
  direction=$1

  if [[ ${direction} = "out" ]]; then
    if [[ ${use_lsof} = 'Y' ]]; then
      peers=$(lsof -Pnl +M -i4 | grep ESTABLISHED | awk -v pid="${CNODE_PID}" -v port=":(${CNODE_PORT}|${EKG_PORT}|${prom_port})->" '$2 == pid && $9 !~ port {print $9}' | awk -F "->" '{print $2}')
    else
      peers=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | awk -v port=":(${CNODE_PORT}|${EKG_PORT}|${prom_port})" '$3 !~ port {print $4}')
    fi
  else
    if [[ ${use_lsof} = 'Y' ]]; then
      peers=$(lsof -Pnl +M -i4 | grep ESTABLISHED | awk -v pid="${CNODE_PID}" -v port=":${CNODE_PORT}->" '$2 == pid && $9 ~ port {print $9}' | awk -F "->" '{print $2}')
    else
      cncli_port=$(ss -tnp state established "( dport = :${CNODE_PORT} )" 2>/dev/null | grep cncli | awk '{print $3}' | cut -d: -f2)
      peers=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | grep -v ":${cncli_port} " | awk -v port=":${CNODE_PORT}" '$3 ~ port {print $4}')
    fi
  fi
  [[ -z ${peers} ]] && return
  
  netstatSorted=$(printf '%s\n' "${peers[@]}" | sort)
  peerCNT=$(wc -w <<< "${peers}")
  
  # Ping every node in the list
  lastpeerIP=""
  for peer in ${netstatSorted}; do
    peerIP=$(echo "${peer}" | cut -d: -f1)
    peerPORT=$(echo "${peer}" | cut -d: -f2)
    [[ -z ${peerIP} || -z ${peerPORT} ]] && continue
    
    if [[ ${direction} = "out" ]]; then
      if [[ -n ${CNCLI} && -f ${CNCLI} && ${DISABLE_CNCLI} != "true" ]]; then
        checkPEER=$(${CNCLI} ping --host "${peerIP}" --port "${peerPORT}" --network-magic "${NWMAGIC}")
        if [[ $(jq -r .status <<< "${checkPEER}") = "ok" ]]; then
          peerRTT=$(jq -r .durationMs <<< "${checkPEER}")
        else # cncli ping failed
          peerRTT=99999
        fi
      elif command -v tcptraceroute >/dev/null; then
        checkPEER=$(tcptraceroute -n -S -f 255 -m 255 -q 1 -w 1 "${peerIP}" "${peerPORT}" 2>&1 | tail -n 1)
        if [[ ${checkPEER} = *'[open]'* ]]; then
          peerRTT=$(echo "${checkPEER}" | awk '{print $4}' | cut -d. -f1)
        else # Nope, no response
          peerRTT=99999
        fi
      elif checkPEER=$(ping -c 2 -i 0.3 -w 1 "${peerIP}" 2>&1); then # Ping OK, show RTT
        peerRTT=$(echo "${checkPEER}" | tail -n 1 | cut -d/ -f5 | cut -d. -f1)
      else # cncli & tcptraceroute missing and ping failed
        peerRTT=99999
      fi
      [[ ${peerRTT} -ne 99999 ]] && peerRTTSUM=$((peerRTTSUM + peerRTT))
    elif [[ "${peerIP}" = "${lastpeerIP}" ]]; then
      [[ ${peerRTT} -ne 99999 ]] && peerRTTSUM=$((peerRTTSUM + peerRTT)) # skip RTT check and reuse old ${peerRTT} number if reachable
    elif checkPEER=$(ping -c 2 -i 0.3 -w 1 "${peerIP}" 2>&1); then # Incoming connection, ping OK, show RTT.
      peerRTT=$(echo "${checkPEER}" | tail -n 1 | cut -d/ -f5 | cut -d. -f1)
      peerRTTSUM=$((peerRTTSUM + peerRTT))
    else # Incoming connection, ping failed, set as unreachable
      peerRTT=99999
    fi
    lastpeerIP=${peerIP}

    # Update counters
      if [[ ${peerRTT} -lt 50    ]]; then ((peerCNT1++))
    elif [[ ${peerRTT} -lt 100   ]]; then ((peerCNT2++))
    elif [[ ${peerRTT} -lt 200   ]]; then ((peerCNT3++))
    elif [[ ${peerRTT} -lt 99999 ]]; then ((peerCNT4++))
    else ((peerCNT0++)); fi
    rttResults+=("${peerRTT}:${peerIP}:${peerPORT} ")
  done
  
  [[ ${#rttResults[@]} ]] && rttResultsSorted=$(printf '%s\n' "${rttResults[@]}" | sort -n)
  
  peerCNTreachable=$((peerCNT-peerCNT0))
  if [[ ${peerCNTreachable} -gt 0 ]]; then
    peerRTTAVG=$((peerRTTSUM / peerCNTreachable))
    peerPCT1=$(echo "scale=4;(${peerCNT1}/${peerCNTreachable})*100" | bc -l)
    peerPCT1items=$(printf %.0f "$(echo "scale=4;${peerPCT1}*${granularity_small}/100" | bc -l)")
    peerPCT2=$(echo "scale=4;(${peerCNT2}/${peerCNTreachable})*100" | bc -l)
    peerPCT2items=$(printf %.0f "$(echo "scale=4;${peerPCT2}*${granularity_small}/100" | bc -l)")
    peerPCT3=$(echo "scale=4;(${peerCNT3}/${peerCNTreachable})*100" | bc -l)
    peerPCT3items=$(printf %.0f "$(echo "scale=4;${peerPCT3}*${granularity_small}/100" | bc -l)")
    peerPCT4=$(echo "scale=4;(${peerCNT4}/${peerCNTreachable})*100" | bc -l)
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
if ! prom_port=$(jq -er '.hasPrometheus[1]' "${CONFIG}" 2>/dev/null); then prom_port=0; fi
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
  uptimens=$(jq '.rts.gc.wall_ms.val //0' <<< "${data}")
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
    if [[ ${use_lsof} = 'Y' ]]; then
      peers_in=$(lsof -Pnl +M -i4 | grep ESTABLISHED | awk -v pid="${CNODE_PID}" -v port=":${CNODE_PORT}->" '$2 == pid && $9 ~ port {print $9}' | awk -F "->" '{print $2}' | wc -l)
      peers_out=$(lsof -Pnl +M -i4 | grep ESTABLISHED | awk -v pid="${CNODE_PID}" -v port=":(${CNODE_PORT}|${EKG_PORT}|${prom_port})->" '$2 == pid && $9 !~ port {print $9}' | awk -F "->" '{print $2}' | wc -l)
    else
      cncli_port=$(ss -tnp state established "( dport = :${CNODE_PORT} )" 2>/dev/null | grep cncli | awk '{print $3}' | cut -d: -f2)
      peers_in=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | grep -v ":${cncli_port} " | awk -v port=":${CNODE_PORT}" '$3 ~ port {print}' | wc -l)
      peers_out=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | awk -v port=":(${CNODE_PORT}|${EKG_PORT}|${prom_port})" '$3 !~ port {print}' | wc -l)
    fi
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
      getEraIdentifier
      PROT_PARAMS="$(${CCLI} query protocol-parameters ${ERA_IDENTIFIER} ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} 2>/dev/null)"
      if [[ -n "${PROT_PARAMS}" ]] && ! DECENTRALISATION=$(jq -re .decentralisationParam <<< ${PROT_PARAMS} 2>/dev/null); then DECENTRALISATION=0.5; fi
    fi
  fi

  header_length=$(( ${#NODE_NAME} + ${#nodemode} + ${#node_version} + ${#node_rev} + ${#NETWORK_NAME} + 19 ))
  [[ ${header_length} -gt ${width} ]] && header_padding=0 || header_padding=$(( (width - header_length) / 2 ))
  printf "%${header_padding}s > ${style_values_2}%s${NC} - ${style_info}(%s - %s)${NC} : ${style_values_1}%s${NC} [${style_values_1}%s${NC}] < \n" "" "${NODE_NAME}" "${nodemode}" "${NETWORK_NAME}" "${node_version}" "${node_rev}" && ((line++))

  ## main section ##
  printf "${tdivider}\n" && ((line++))
  printf "${VL} Uptime: ${style_values_1}%s${NC}" "$(timeLeft $(( uptimens/1000 )))"
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
    peerCNT_out=${peerCNT}; peerCNT0_out=${peerCNT0}; peerCNT1_out=${peerCNT1}; peerCNT2_out=${peerCNT2}; peerCNT3_out=${peerCNT3}; peerCNT4_out=${peerCNT4}
    peerPCT1_out=${peerPCT1}; peerPCT2_out=${peerPCT2}; peerPCT3_out=${peerPCT3}; peerPCT4_out=${peerPCT4}
    peerPCT1items_out=${peerPCT1items}; peerPCT2items_out=${peerPCT2items}; peerPCT3items_out=${peerPCT3items}; peerPCT4items_out=${peerPCT4items}
    peerRTTAVG_out=${peerRTTAVG}; rttResultsSorted_out=${rttResultsSorted}
    peerNbr_start_out=1
    tput cup ${line} 0
    tput ed
    printf "${VL} ${style_info}%-$((width-3))s${NC} ${VL}\n" "Output peer analysis done!" && ((line++))
      
    echo "${m2divider}" && ((line++))

    printf "${VL} ${style_info}%-$((width-3))s${NC} ${VL}\n" "Input peer analysis started... please wait!" && ((line++))
    echo "${bdivider}" && ((line++))
    checkPeers in
    # Save values
    peerCNT_in=${peerCNT}; peerCNT0_in=${peerCNT0}; peerCNT1_in=${peerCNT1}; peerCNT2_in=${peerCNT2}; peerCNT3_in=${peerCNT3}; peerCNT4_in=${peerCNT4}
    peerPCT1_in=${peerPCT1}; peerPCT2_in=${peerPCT2}; peerPCT3_in=${peerPCT3}; peerPCT4_in=${peerPCT4}
    peerPCT1items_in=${peerPCT1items}; peerPCT2items_in=${peerPCT2items}; peerPCT3items_in=${peerPCT3items}; peerPCT4items_in=${peerPCT4items}
    peerRTTAVG_in=${peerRTTAVG}; rttResultsSorted_in=${rttResultsSorted}
    peerNbr_start_in=1
    printf -v peer_analysis_date '%(%Y-%m-%d %H:%M:%S)T\n' -1
  elif [[ ${show_peers} = "true" && ${show_peers_info} = "true" ]]; then
    printf "${VL}${STANDOUT} INFO ${NC} One-shot peer analysis last run at ${style_values_1}%s${NC}" "${peer_analysis_date}" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    echo "${blank_line}" && ((line++))
    printf "${VL} Runs a latency test on incoming/outgoing connections to the" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} node. Once the analysis is finished, RTTs(Round Trip Time)" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} for each peer is display and grouped in ranges of" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} 0-50, 50-100, 100-200, 200<." && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    echo "${blank_line}" && ((line++))
    printf "${VL} Outgoing connections ping type order(peers in own topology):" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} 1. ${style_values_2}cncli${NC} - If available, this gives the most accurate" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL}    measure as it checks the entire handshake process against" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL}    the remote peer." && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} 2. ${style_values_2}tcptraceroute${NC} - Sends a TCP SYN package to ping the" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL}    remote peer on the cardano-node port. Should give ~100%%" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL}    success rate." && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} 3. ${style_values_2}ping${NC} - fallback method using ICMP ping against IP." && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL}    Only work if the FW of remote peer accepts ICMP traffic." && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    echo "${blank_line}" && ((line++))
    printf "${VL} For incoming connections, only ICMP ping is used as remote" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} peer port is unknown. It's not uncommon to see many" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} unreachable peers for incoming connections as it's a good" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} security practice to disable ICMP in firewall." && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
  elif [[ ${show_peers} = "true" ]]; then    
    printf "${VL}${STANDOUT} OUT ${NC}  RTT : Peers / Percent" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))

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
    
    echo "${m3divider}" && ((line++))
    
    printf "${VL} Total / Unreachable : ${style_values_1}%s${NC} / " "${peerCNT_out}"
    [[ ${peerCNT0_out} -eq 0 ]] && printf "${style_values_1}0${NC}" || printf "${style_status_3}%s${NC}" "${peerCNT0_out}"
    tput cup ${line} $((second_col-1))
    if [[ ${peerRTTAVG_out} -ge 200 ]]; then printf "Average RTT : ${style_status_4}%s${NC} ms" "${peerRTTAVG_out}"
    elif [[ ${peerRTTAVG_out} -ge 100 ]]; then printf "Average RTT : ${style_status_3}%s${NC} ms" "${peerRTTAVG_out}"
    elif [[ ${peerRTTAVG_out} -ge 50  ]]; then printf "Average RTT : ${style_status_2}%s${NC} ms" "${peerRTTAVG_out}"
    elif [[ ${peerRTTAVG_out} -ge 0   ]]; then printf "Average RTT : ${style_status_1}%s${NC} ms" "${peerRTTAVG_out}"
    else printf "Average RTT : ${style_status_3}---${NC} ms"; fi
    tput cup ${line} ${width}
    printf "${VL}\n" && ((line++))

    if [[ -n ${rttResultsSorted_out} ]]; then
      echo "${m3divider}" && ((line++))
      
      printf "${VL}${style_info}   # : %20s   : RTT (ms)${NC}\n" "REMOTE PEER"
      header_line=$((line++))
      
      peerNbr_out=0
      for peer in ${rttResultsSorted_out}; do
        ((peerNbr_out++))
        [[ ${peerNbr_out} -lt ${peerNbr_start_out} ]] && continue
        peerRTT=$(echo ${peer} | cut -d: -f1)
        peerIP=$(echo ${peer} | cut -d: -f2)
        peerPORT=$(echo ${peer} | cut -d: -f3)
          if [[ ${peerRTT} -lt 50    ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_1}%-5s${NC} %$((width-39))s${VL}\n" ${peerNbr_out} ${peerIP} ${peerPORT} ${peerRTT}
        elif [[ ${peerRTT} -lt 100   ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_2}%-5s${NC} %$((width-39))s${VL}\n" ${peerNbr_out} ${peerIP} ${peerPORT} ${peerRTT}
        elif [[ ${peerRTT} -lt 200   ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_3}%-5s${NC} %$((width-39))s${VL}\n" ${peerNbr_out} ${peerIP} ${peerPORT} ${peerRTT}
        elif [[ ${peerRTT} -lt 99999 ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_4}%-5s${NC} %$((width-39))s${VL}\n" ${peerNbr_out} ${peerIP} ${peerPORT} ${peerRTT}
        else printf "${VL} %3s : %15s:%-6s : --- %$((width-37))s${VL}\n" ${peerNbr_out} ${peerIP} ${peerPORT}; fi
        ((line++))
        [[ ${peerNbr_out} -eq $((peerNbr_start_out+7)) ]] && break
      done
      
      [[ ${peerNbr_start_out} -gt 1 ]] && nav_str="< " || nav_str=""
      nav_str+="[${peerNbr_start_out}-${peerNbr_out}]"
      [[ ${peerCNT_out} -gt ${peerNbr_out} ]] && nav_str+=" >"
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
    
    echo "${m3divider}" && ((line++))
    
    printf "${VL} Total / Unreachable : ${style_values_1}%s${NC} / " "${peerCNT_in}"
    [[ ${peerCNT0_in} -eq 0 ]] && printf "${style_values_1}0${NC}" || printf "${style_status_3}%s${NC}" "${peerCNT0_in}"
    tput cup ${line} $((second_col-1))
    if [[ ${peerRTTAVG_in} -ge 200 ]]; then printf "Average RTT : ${style_status_4}%s${NC} ms" "${peerRTTAVG_in}"
    elif [[ ${peerRTTAVG_in} -ge 100 ]]; then printf "Average RTT : ${style_status_3}%s${NC} ms" "${peerRTTAVG_in}"
    elif [[ ${peerRTTAVG_in} -ge 50  ]]; then printf "Average RTT : ${style_status_2}%s${NC} ms" "${peerRTTAVG_in}"
    elif [[ ${peerRTTAVG_in} -ge 0   ]]; then printf "Average RTT : ${style_status_1}%s${NC} ms" "${peerRTTAVG_in}"
    else printf "Average RTT : ${style_status_3}---${NC} ms"; fi
    tput cup ${line} ${width}
    printf "${VL}\n" && ((line++))
    
    if [[ -n ${rttResultsSorted_in} ]]; then
      echo "${m3divider}" && ((line++))
      
      printf "${VL}${style_info}   # : %20s   : RTT (ms)${NC}\n" "REMOTE PEER"
      header_line=$((line++))
      
      peerNbr_in=0
      for peer in ${rttResultsSorted_in}; do
        ((peerNbr_in++))
        [[ ${peerNbr_in} -lt ${peerNbr_start_in} ]] && continue
        peerRTT=$(echo ${peer} | cut -d: -f1)
        peerIP=$(echo ${peer} | cut -d: -f2)
        peerPORT=$(echo ${peer} | cut -d: -f3)
          if [[ ${peerRTT} -lt 50    ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_1}%-5s${NC} %$((width-39))s${VL}\n" ${peerNbr_in} ${peerIP} ${peerPORT} ${peerRTT}
        elif [[ ${peerRTT} -lt 100   ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_2}%-5s${NC} %$((width-39))s${VL}\n" ${peerNbr_in} ${peerIP} ${peerPORT} ${peerRTT}
        elif [[ ${peerRTT} -lt 200   ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_3}%-5s${NC} %$((width-39))s${VL}\n" ${peerNbr_in} ${peerIP} ${peerPORT} ${peerRTT}
        elif [[ ${peerRTT} -lt 99999 ]]; then printf "${VL} %3s : %15s:%-6s : ${style_status_4}%-5s${NC} %$((width-39))s${VL}\n" ${peerNbr_in} ${peerIP} ${peerPORT} ${peerRTT}
        else printf "${VL} %3s : %15s:%-6s : --- %$((width-37))s${VL}\n" ${peerNbr_in} ${peerIP} ${peerPORT}; fi
        ((line++))
        [[ ${peerNbr_in} -eq $((peerNbr_start_in+7)) ]] && break
      done
      
      [[ ${peerNbr_start_in} -gt 1 ]] && nav_str="< " || nav_str=""
      nav_str+="[${peerNbr_start_in}-${peerNbr_in}]"
      [[ ${peerCNT_in} -gt ${peerNbr_in} ]] && nav_str+=" >"
      tput cup ${header_line} $((width-${#nav_str}-3))
      [[ ${selected_direction} = "in" ]] && printf "${style_values_3} %s ${NC} ${VL}\n" "${nav_str}" || printf "  %s ${VL}\n" "${nav_str}"
      tput cup ${line} 0
    fi
  elif [[ ${show_home_info} = "true" ]]; then
    printf "${VL}${STANDOUT} INFO ${NC} Displays live metrics gathered from node EKG endpoint" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    echo "${blank_line}" && ((line++))
    printf "${VL} ${style_values_2}Upper Main Section${NC}" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} Epoch number & progress is live from node while calculation" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} of date until epoch boundary is based on genesis parameters." && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} Reference tip is also a calculation based on genesis values" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} used to compare against the node tip to see how far of the" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} tip(diff value) the node is. This interval is dynamic and" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} based on different genesis parameters. In/Out peers show how" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} many connections the node have established in and out." && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    echo "${blank_line}" && ((line++))
    printf "${VL} ${style_values_2}Core section${NC}" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} If the node is run as a block producer, a second section is" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} displayed that contain KES key and block stats. When close" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} to the expire date the values will change color." && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    echo "${blank_line}" && ((line++))
    printf "${VL} If CNCLI is activated to calculate and store node blocks," && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} data from this blocklog DB is displayed. If not, blocks" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} created is taken from EKG metrics. Invalid, Missed, Ghosted" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} and Stolen only showed if non-zero for the epoch." && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    echo "${blank_line}" && ((line++))
    printf "${VL} - Leader    : scheduled to make block at this slot" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} - Ideal     : Expected/Ideal number of blocks assigned" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL}               based on active stake (sigma)" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} - Luck      : Leader slots assigned vs Ideal slots" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} - Adopted   : block created successfully" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} - Confirmed : block created validated to be on-chain" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} - Invalid   : node failed to create block" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} - Missed    : scheduled at slot but no record of it in " && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL}               cncli DB and no other pool has made a block" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL}               for this slot" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} - Ghosted   : block created but marked as orphaned and no" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL}               other pool has made a valid block for this" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL}               slot, height battle or block propagation issue" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL} - Stolen    : another pool has a valid block registered" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
    printf "${VL}               on-chain for the same slot" && tput cup ${line} ${width} && printf "${VL}\n" && ((line++))
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
    printf "${VL} Slot    : ${style_values_1}%-$((second_col-12))s${NC}" "${slot_in_epoch}"
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
    elif [[ ${tip_diff} -le $(( $(slotInterval) * 4 )) ]]; then
      printf "Tip (diff) : ${style_status_2}%-${sec_col_value_size}s${NC}${VL}\n" "${tip_diff} :|"
    else
      sync_progress=$(echo "(${slotnum}/${tip_ref})*100" | bc -l)
      printf "Status     : ${style_info}%-${sec_col_value_size}s${NC}${VL}\n" "syncing ($(printf "%2.1f" "${sync_progress}")%)"
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
      
      if [[ -f "${BLOCKLOG_DB}" ]]; then
        invalid_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epochnum} AND status='invalid';" 2>/dev/null)
        missed_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epochnum} AND status='missed';" 2>/dev/null)
        ghosted_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epochnum} AND status='ghosted';" 2>/dev/null)
        stolen_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epochnum} AND status='stolen';" 2>/dev/null)
        confirmed_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epochnum} AND status='confirmed';" 2>/dev/null)
        adopted_cnt=$(( $(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epochnum} AND status='adopted';" 2>/dev/null) + confirmed_cnt ))
        leader_cnt=$(( $(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${epochnum} AND status='leader';" 2>/dev/null) + adopted_cnt + invalid_cnt + missed_cnt + ghosted_cnt + stolen_cnt ))
        OLDIFS=$IFS && IFS='|' && read -ra epoch_stats <<< "$(sqlite3 "${BLOCKLOG_DB}" "SELECT epoch_slots_ideal, max_performance FROM epochdata WHERE epoch=${epochnum};" 2>/dev/null)" && IFS=$OLDIFS
        if [[ ${#epoch_stats[@]} -eq 0 ]]; then epoch_stats=("-" "-"); else epoch_stats[1]="${epoch_stats[1]}%"; fi

        [[ ${invalid_cnt} -eq 0 ]] && invalid_fmt="${NC}" || invalid_fmt="${style_status_3}"
        [[ ${missed_cnt} -eq 0 ]] && missed_fmt="${NC}" || missed_fmt="${style_status_3}"
        [[ ${ghosted_cnt} -eq 0 ]] && ghosted_fmt="${NC}" || ghosted_fmt="${style_status_3}"
        [[ ${stolen_cnt} -eq 0 ]] && stolen_fmt="${NC}" || stolen_fmt="${style_status_3}"
        [[ ${adopted_cnt} -eq 0 ]] && adopted_fmt="${NC}" || adopted_fmt="${style_values_1}"
        if [[ ${confirmed_cnt} -eq 0 ]]; then confirmed_fmt="${NC}"; else [[ ${confirmed_cnt} -eq ${adopted_cnt} ]] && confirmed_fmt="${style_status_1}" || confirmed_fmt="${style_status_2}"; fi
        [[ ${leader_cnt} -eq 0 ]] && leader_fmt="${NC}" || leader_fmt="${style_values_1}"
        
        printf "${VL}${STANDOUT} BLOCKS ${NC}  Leader | Ideal | Luck       Adopted | Confirmed%$((width-58))s${VL}\n" "" && ((line++))
        printf "${VL}%10s${leader_fmt}%-9s%-8s%-11s${adopted_fmt}%-10s${confirmed_fmt}%-9s${NC}%$((width-58))s${VL}\n" "" "${leader_cnt}" "${epoch_stats[0]}" "${epoch_stats[1]}" "${adopted_cnt}" "${confirmed_cnt}" "" && ((line++))
        
        if [[ ${invalid_cnt} -ne 0 || ${missed_cnt} -ne 0 || ${ghosted_cnt} -ne 0 || ${stolen_cnt} -ne 0 ]]; then
          echo "${m3divider}" && ((line++))
          printf "${VL}%10sInvalid | Missed | Ghosted | Stolen%$((width-46))s${VL}\n" "" && ((line++))
          printf "${VL}%10s${invalid_fmt}%-10s${missed_fmt}%-9s${ghosted_fmt}%-10s${stolen_fmt}%-6s${NC}%$((width-46))s${VL}\n" "" "${invalid_cnt}" "${missed_cnt}" "${ghosted_cnt}" "${stolen_cnt}" "" && ((line++))
        fi
      else
        printf "${VL}${STANDOUT} BLOCKS ${NC} %$((width-38))s %-6s | ${FG_GREEN}%-7s${NC} | ${FG_RED}%-7s${NC} ${VL}\n" "" "Leader" "Adopted" "Invalid" && ((line++))
        printf "${VL}%s %$((width-60))s %-6s | %-7s | %-7s ${VL}\n" "Since node start (EKG metrics)" "" "${isleader}" "${adopted}" "${didntadopt}" && ((line++))
      fi
    fi
  fi
  
  [[ ${check_peers} = "true" ]] && check_peers=false && show_peers=true && clear && continue
  
  echo "${bdivider}" && ((line++))
  if [[ ${show_peers} = "true" && ${show_peers_info} = "true" ]]; then
    printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[b] Back to Peer Analysis${NC}"
    tput el
    waitForInput "peersInfo"
  elif [[ ${show_peers} = "true" ]]; then
    printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[h] Home${NC} | ${style_info}[i] Info${NC} | Up/Down    : Select List\n%38s%s" "" "Left/Right : Navigate List"
    tput el
    waitForInput "peers"
  elif [[ ${show_home_info} = "true" ]]; then
    printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[h] Home${NC}"
    tput el
    waitForInput "homeInfo"
  else
    printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[i] Info${NC} | ${style_info}[p] Peer Analysis${NC}"
    tput el
    waitForInput
  fi
done
