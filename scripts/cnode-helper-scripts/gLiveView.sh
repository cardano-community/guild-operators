#!/usr/bin/env bash
#shellcheck disable=SC2009,SC2034,SC2059,SC2206,SC2086,SC2015,SC2154
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

NODE_NAME="Cardano Node"                  # Change your node's name prefix here, keep at or below 19 characters!
REFRESH_RATE=2                            # How often (in seconds) to refresh the view (additional time for processing and output may slow it down)
LEGACY_MODE=false                         # (true|false) If enabled unicode box-drawing characters will be replaced by standard ASCII characters
RETRIES=3                                 # How many attempts to connect to running Cardano node before erroring out and quitting
PEER_LIST_CNT=6                           # Number of peers to show on each in/out page in peer analysis view
THEME="dark"                              # dark  = suited for terminals with a dark background
                                          # light = suited for terminals with a bright background
#ENABLE_IP_GEOLOCATION="Y"                # Enable IP geolocation on outgoing and incoming connections using ip-api.com (default: Y)
#LATENCY_TOOLS="cncli|ss|tcptraceroute|ping" # Preferred latency check tool order, valid entries: cncli|ss|tcptraceroute|ping (must be separated by |)
#CNCLI_CONNECT_ONLY=false                 # By default cncli measure full connect handshake duration. If set to false, only connect is measured similar to other tools

#####################################
# Themes                            #
#####################################

setTheme() {
  if [[ ${THEME} = "dark" ]]; then
    style_title=${FG_MAGENTA}${BOLD}      # style of title
    style_base=${FG_WHITE}                # default color for text and lines
    style_values_1=${FG_LBLUE}            # color of most live values
    style_values_2=${FG_GREEN}            # color of node name
    style_values_3=${STANDOUT}            # color of selected outgoing/incoming paging
    style_values_4=${FG_LGRAY}               # color of informational text
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
    style_values_4=${FG_LGRAY}               # color of informational text
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

GLV_VERSION=v1.22.4

PARENT="$(dirname $0)"

# Set default for user variables added in recent versions (for those who may not necessarily have it due to upgrade)
[[ -z "${RETRIES}" ]]  && RETRIES=3

usage() {
  cat <<-EOF
		Usage: $(basename "$0") [-l] [-p] [-b <branch name>]
		Guild LiveView - An alternative cardano-node LiveView

		-l    Activate legacy mode - standard ASCII characters instead of box-drawing characters
		-b    Use alternate branch to check for updates - only for testing/development (Default: Master)
		EOF
  exit 1
}

while getopts :lb: opt; do
  case ${opt} in
    l ) LEGACY_MODE="true" ;;
    b ) echo "${OPTARG}" > "${PARENT}"/.env_branch ;;
    \? ) usage ;;
  esac
done
shift $((OPTIND -1))

# General exit handler
cleanup() {
  [[ -n $1 ]] && err=$1 || err=$?
  [[ $err -eq 0 ]] && clear
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

#######################################################
# Version Check                                       #
#######################################################
clear

if [[ ! -f "${PARENT}"/env ]]; then
  echo -e "\nCommon env file missing: ${PARENT}/env"
  echo -e "This is a mandatory prerequisite, please install with prereqs.sh or manually download from GitHub\n"
  myExit 1
fi

. "${PARENT}"/env &>/dev/null # ignore any errors, re-sourced later

if [[ "${UPDATE_CHECK}" == "Y" ]]; then
  echo "Checking for script updates..."
  # Check availability of checkUpdate function
  if [[ ! $(command -v checkUpdate) ]]; then
    echo -e "\nCould not find checkUpdate function in env, make sure you're using official guild docos for installation!"
    myExit 1
  fi
  # check for env update
  ! checkUpdate env && myExit 1
  # source common env variables in case it was updated
  . "${PARENT}"/env
  case $? in
    1) myExit 1 "ERROR: gLiveView failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" ;;
    2) clear ;;
  esac

  if curl -s -f -m ${CURL_TIMEOUT} -o "${PARENT}"/gLiveView.sh.tmp ${URL}/gLiveView.sh 2>/dev/null && [[ -f "${PARENT}"/gLiveView.sh.tmp ]]; then
    GIT_VERSION=$(grep -r ^GLV_VERSION= "${PARENT}"/gLiveView.sh.tmp | cut -d'=' -f2)
    : "${GIT_VERSION:=v0.0.0}"
    if ! versionCheck "${GIT_VERSION}" "${GLV_VERSION}"; then
      echo -e "\nA new version of Guild LiveView is available"
      echo "Installed Version : ${GLV_VERSION}"
      echo "Available Version : ${GIT_VERSION}"
      if getAnswer "\nDo you want to upgrade to the latest version of Guild LiveView?"; then
        TEMPL_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/gLiveView.sh.tmp)
        STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/gLiveView.sh)
        printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL_CMD" > "${PARENT}"/gLiveView.sh.tmp
        mv -f "${PARENT}"/gLiveView.sh "${PARENT}/gLiveView.sh_bkp$(printf '%(%s)T\n' -1)" && \
        mv -f "${PARENT}"/gLiveView.sh.tmp "${PARENT}"/gLiveView.sh && \
        chmod 750 "${PARENT}"/gLiveView.sh && \
        myExit 0 "Update applied successfully!\n\nPlease start Guild LiveView again!" || \
        myExit 1 "${FG_RED}Update failed!${NC}\n\nPlease use prereqs.sh or manually download to update gLiveView"
      fi
    fi
  else
    echo -e "\nFailed to download gLiveView.sh from GitHub, unable to perform version check!"
    waitToProceed && clear
  fi
  rm -f "${PARENT}"/gLiveView.sh.tmp
else
  # source common env variables in offline mode
  . "${PARENT}"/env offline
  case $? in
    1) myExit 1 "ERROR: gLiveView failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" ;;
    2) clear ;;
  esac
fi

#######################################################
# Validate config variables                           #
# Can be overridden in 'User Variables' section above #
#######################################################

[[ ${#NODE_NAME} -gt 19 ]] && myExit 1 "Please keep node name at or below 19 characters in length!"

[[ ! ${REFRESH_RATE} =~ ^[0-9]+$ ]] && myExit 1 "Please set a valid refresh rate number!"

[[ -z ${ENABLE_IP_GEOLOCATION} ]] && ENABLE_IP_GEOLOCATION=Y
declare -gA geoIP=()
[[ -f "$0.geodb" ]] && . -- "$0.geodb"

[[ -z ${PEER_LIST_CNT} ]] && PEER_LIST_CNT=6

[[ -z ${LATENCY_TOOLS} ]] && LATENCY_TOOLS="cncli|ss|tcptraceroute|ping"

[[ -z ${CNCLI_CONNECT_ONLY} ]] && CNCLI_CONNECT_ONLY=false

#######################################################
# Style / UI                                          #
#######################################################
width=71

# two column view
two_col_width=$(( (width-3)/2 ))
two_col_second=$(( two_col_width + 2 ))

# three column view
three_col_width=$(( (width-5)/3 ))
three_col_2_start=$(( three_col_width + 3 ))
three_col_3_start=$(( three_col_width*2 + 4 ))
# main section
three_col_1_value_width=$(( three_col_width - 12 ))   # minus max width of Block|Slot|Density|Total Tx|Pending Tx + " : "
three_col_2_value_width=$(( three_col_width - 12 ))   # minus max width of Tip (ref)|Tip (node)|Tip (diff)|Peers In|Peers Out + " : "
three_col_3_value_width=$(( three_col_width - 12 ))    # minus max width of Mem (RSS)|Mem (Live)|Mem (Heap)|GC Minor|GC Major + " : "
# block section use same width as main section now

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
  coredivider=$(printf "${NC}|= ${style_info}CORE${NC} " && printf "%0.s=" $(seq $((width-8))) && printf "|")
  blockdivider=$(printf "${NC}|- ${style_info}BLOCKS${NC} " && printf "%0.s-" $(seq $((width-10))) && printf "|")
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
  tdivider=$(printf "${NC}\\u250C" && printf "%0.s\\u2500" $(seq $((width-${#title}-${#CNODE_PORT}-13))) && printf "\\u252C" && printf "%0.s\\u2500" $(seq $((${#CNODE_PORT}+8))) && printf "\\u252C" && printf "%0.s\\u2500" $(seq $((${#title}+2))) && printf "\\u2510")
  mdivider=$(printf "${NC}\\u251C" && printf "%0.s\\u2500" $(seq $((width-1))) && printf "\\u2524")
  m2divider=$(printf "${NC}\\u2502" && printf "%0.s-" $(seq $((width-1))) && printf "\\u2502")
  m3divider=$(printf "${NC}\\u2502" && printf "%0.s- " $(seq $((width/2))) && printf "\\u2502")
  bdivider=$(printf "${NC}\\u2514" && printf "%0.s\\u2500" $(seq $((width-1))) && printf "\\u2518")
  coredivider=$(printf "${NC}\\u251C\\u2500 ${style_info}CORE${NC} " && printf "%0.s\\u2500" $(seq $((width-8))) && printf "\\u2524")
  blockdivider=$(printf "${NC}\\u2502- ${style_info}BLOCKS${NC} " && printf "%0.s-" $(seq $((width-10))) && printf "\\u2502")
  blank_line=$(printf "${NC}\\u2502%$((width-1))s\\u2502" "")
fi

#####################################
# Helper functions                  #
#####################################

# Command     : waitForInput [submenu]
# Description : wait for user keypress to quit, else do nothing if timeout expire
waitForInput() {
  ESC=$(printf "\033")
  if [[ $1 = "homeInfo" || $1 = "peersInfo" ]]; then read -rsn1 key1
  elif ! read -rsn1 -t ${REFRESH_RATE} key1; then return; fi
  [[ ${key1} = "${ESC}" ]] && read -rsn2 -t 0.3 key2 # read 2 more chars
  [[ ${key1} = "q" ]] && myExit 0 "Guild LiveView stopped!"
  [[ ${key1} = "${ESC}" && ${key2} = "" ]] && myExit 0 "Guild LiveView stopped!"
  if [[ $# -eq 0 ]]; then
    [[ ${key1} = "p" ]] && check_peers="true" && clrScreen && return
    [[ ${key1} = "i" ]] && show_home_info="true" && clrScreen && return
  elif [[ $1 = "homeInfo" ]]; then
    [[ ${key1} = "h" ]] && show_home_info="false" && line=0 && clrScreen && return
  elif [[ $1 = "peersInfo" ]]; then
    [[ ${key1} = "b" ]] && show_peers_info="false" && line=0 && clrScreen && return
  elif [[ $1 = "peers" ]]; then
    [[ ${key1} = "h" ]] && show_peers="false" && clrScreen && return
    [[ ${key1} = "i" ]] && show_peers_info="true" && clrScreen && return
    [[ ${key2} = "[A" ]] && selected_direction="out" && return # Up arrow
    [[ ${key2} = "[B" ]] && selected_direction="in" && return # Down arrow
    if [[ ${key2} = "[C" && ${show_peers} = "true" ]]; then # Right arrow
      [[ ${selected_direction} = "out" && ${peerCNT_out} -gt ${peerNbr_out} ]] && peerNbr_start_out=$((peerNbr_start_out+PEER_LIST_CNT)) && clrScreen && return
      [[ ${selected_direction} = "in" && ${peerCNT_in} -gt ${peerNbr_in} ]] && peerNbr_start_in=$((peerNbr_start_in+PEER_LIST_CNT)) && clrScreen && return
    fi
    if [[ ${key2} = "[D" && ${show_peers} = "true" ]]; then # Left arrow
      [[ ${selected_direction} = "out" && ${peerNbr_start_out} -gt ${PEER_LIST_CNT} ]] && peerNbr_start_out=$((peerNbr_start_out-PEER_LIST_CNT)) && clrScreen && return
      [[ ${selected_direction} = "in" && ${peerNbr_start_in} -gt ${PEER_LIST_CNT} ]] && peerNbr_start_in=$((peerNbr_start_in-PEER_LIST_CNT)) && clrScreen && return
    fi
  fi
}

# Command    : sizeOfProgressSlotSpan
# Description: Determine and set the size and style of the progress bar based on remaining time
# Return     : sets leader_bar_span as integer [432000, 43200, 3600, 300]
#            : sets leader_bar_style using styling from theme
setSizeAndStyleOfProgressBar() {
  if [[ ${1} -gt 43200 ]]; then
    leader_bar_span=432000
    leader_bar_style="${style_status_1}"
  elif [[ ${1} -gt 3600 ]]; then
    leader_bar_span=43200
    leader_bar_style="${style_status_2}"
  elif [[ ${1} -gt 300 ]]; then
    leader_bar_span=3600
    leader_bar_style="${style_status_3}"
  else
    leader_bar_span=300
    leader_bar_style="${style_status_4}"
  fi
}

# Command    : alignLeft <nbr chars> <string>
# Description: printf align helpers useful to handle umlauts correctly
alignLeft () {
  (($#==2)) || return 2
  ((${#2}>$1)) && return 1
  printf '%s%*s' "$2" $(($1-${#2})) ''
}
# Command    : alignRight <nbr chars> <string>
alignRight () {
  (($#==2)) || return 2
  ((${#2}>$1)) && return 1
  printf '%*s%s' $(($1-${#2})) '' "$2"
}

# Command    : mvRight <nbr columns>
# Description: move curser x columns to the right
mvRight () {
  printf "\033[${1}C"
}
# Command    : mvLeft <nbr columns>
# Description: move curser x columns to the left
mvLeft () {
  printf "\033[${1}D"
}
# Command    : mvPos <line nbr> <column nbr>
# Description: move curser to specified position
mvPos () {
  printf "\033[$1;$2H"
}
# Command    : mvTwoSecond
# Description: move curser to two column view, second column start
mvTwoSecond () {
  printf "\033[72D\033[${two_col_second}C"
}
# Command    : mvThreeSecond
# Description: move curser to three column view, second column start
mvThreeSecond () {
  printf "\033[72D\033[${three_col_2_start}C"
}
# Command    : mvThreeThird
# Description: move curser to three column view, third column start
mvThreeThird () {
  printf "\033[72D\033[${three_col_3_start}C"
}
# Command    : mvEnd
# Description: move curser to last column
mvEnd () {
  printf "\033[72D\033[${width}C"
}
# Command    : closeRow
# Description: move curser to last column, print border and newline and finally increment line number
closeRow () {
  printf "${NC}\033[72D\033[${width}C${VL}\n" && ((line++))
}
# Command    : clrLine
# Description: clear to end of line
clrLine () {
  printf "\033[K"
}
# Command    : clrScreen
# Description: clear the screen, move to (0,0)
clrScreen () {
  printf "\033[2J"
}

# Description: latency helper functions
latencyCNCLI () {
  if [[ -n ${CNCLI} && -f ${CNCLI} ]]; then
    checkPEER=$(${CNCLI} ping --host "${peerIP}" --port "${peerPORT}" --network-magic "${NWMAGIC}")
    if [[ $(jq -r .status <<< "${checkPEER}") = "ok" ]]; then
      [[ ${CNCLI_CONNECT_ONLY} = true ]] && peerRTT=$(jq -r .connectDurationMs <<< "${checkPEER}") || peerRTT=$(jq -r .durationMs <<< "${checkPEER}")
    else # cncli ping failed
      peerRTT=99999
    fi
  fi
}
latencySS () {
  if command -v ss >/dev/null; then
    if [[ $(ss -ni "dst ${peerIP}:${peerPORT}" | tail -1) =~ rtt:([0-9]+) ]]; then
      peerRTT=${BASH_REMATCH[1]}
    else
      peerRTT=99999
    fi
  fi
}
latencyTCPTRACEROUTE () {
  if command -v tcptraceroute >/dev/null; then
    checkPEER=$(tcptraceroute -n -S -f 255 -m 255 -q 1 -w 1 "${peerIP}" "${peerPORT}" 2>&1 | tail -n 1)
    if [[ ${checkPEER} = *'[open]'* ]]; then
      peerRTT=$(echo "${checkPEER}" | awk '{print $4}' | cut -d. -f1)
    else # Nope, no response
      peerRTT=99999
    fi
  fi
}
latencyPING () {
  if checkPEER=$(ping -c 2 -i 0.3 -w 1 "${peerIP}" 2>&1); then # Ping OK, show RTT
    peerRTT=$(echo "${checkPEER}" | tail -n 1 | cut -d/ -f5 | cut -d. -f1)
  fi
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
  geoIPquery="[]"; geoIPqueryCNT=0
  direction=$1

  if [[ ${direction} = "out" ]]; then
    if [[ ${use_lsof} = 'Y' ]]; then
      peers=$(lsof -Pnl +M | grep ESTABLISHED | awk -v pid="${CNODE_PID}" -v port=":(${CNODE_PORT}|${EKG_PORT}|${PROM_PORT})->" '$2 == pid && $9 !~ port {print $9}' | awk -F "->" '{print $2}')
    else
      peers=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | awk -v port=":(${CNODE_PORT}|${EKG_PORT}|${PROM_PORT})" '$3 !~ port {print $4}')
    fi
  else
    if [[ ${use_lsof} = 'Y' ]]; then
      peers=$(lsof -Pnl +M | grep ESTABLISHED | awk -v pid="${CNODE_PID}" -v port=":${CNODE_PORT}->" '$2 == pid && $9 ~ port {print $9}' | awk -F "->" '{print $2}')
    else
      cncli_port=$(ss -tnp state established "( dport = :${CNODE_PORT} )" 2>/dev/null | grep cncli | awk '{print $3}' | cut -d: -f2)
      peers=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | grep -v ":${cncli_port} " | awk -v port=":${CNODE_PORT}" '$3 ~ port {print $4}')
    fi
  fi
  [[ -z ${peers} ]] && return

  peersSorted=$(printf '%s\n' "${peers[@]}" | sort)
  peerCNT=$(wc -w <<< "${peers}")

  print_start=$(( width - (${#peerCNT}*2) - 2 ))
  mvPos ${line} ${print_start}
  printf "${style_values_1}%${#peerCNT}s${NC}/${style_values_2}%s${NC}" "0" "${peerCNT}"

  # Ping every node in the list
  index=0
  lastpeerIP=""

  for peer in ${peersSorted}; do

    if [[ ${peer} = "["* ]]; then # IPv6
      IFS=']' read -ra ipv6_peer <<< "${peer:1}"
      peerIP=${ipv6_peer[0]}
      peerPORT=${ipv6_peer[1]:1}
    else # IPv4
      peerIP=$(cut -d: -f1 <<< "${peer}")
      peerPORT=$(cut -d: -f2 <<< "${peer}")
    fi

    [[ -z ${peerIP} || -z ${peerPORT} ]] && mvPos ${line} ${print_start} && printf "${style_values_1}%${#peerCNT}s${NC}" "$((++index))" && continue

    if [[ ${ENABLE_IP_GEOLOCATION} = "Y" && "${peerIP}" != "${lastpeerIP}" ]] && ! isPrivateIP "${peerIP}"; then
      if [[ ! -v "geoIP[${peerIP}]" && $((++geoIPqueryCNT)) -le 100 ]]; then # not previously checked and less than 100 queries
        geoIPquery=$(jq --arg addr "${peerIP}" '. += [{"query": $addr, "fields": "city,countryCode,query"}]' <<< ${geoIPquery})
      fi
    fi

    if [[ "${peerIP}" = "${lastpeerIP}" ]]; then
      [[ ${peerRTT} -ne 99999 ]] && peerRTTSUM=$((peerRTTSUM + peerRTT)) # skip RTT check and reuse old ${peerRTT} number if reachable
    elif [[ ${direction} = "out" ]]; then
      unset peerRTT
      for tool in ${LATENCY_TOOLS//|/ }; do
        case ${tool} in
          cncli) 
            latencyCNCLI ;;
          ss)    
            latencySS ;;
          tcptraceroute) 
            latencyTCPTRACEROUTE ;;
          ping)
            latencyPING ;;
        esac
        [[ -n ${peerRTT} && ${peerRTT} != 99999 ]] && break
      done
      if [[ -z ${peerRTT} ]]; then # cncli, ss & tcptraceroute and ping failed
        peerRTT=99999
      fi
      ! isNumber ${peerRTT} && peerRTT=99999 || peerRTTSUM=$((peerRTTSUM + peerRTT))
    elif checkPEER=$(ping -c 2 -i 0.3 -w 1 "${peerIP}" 2>&1); then # Incoming connection, ping OK, show RTT.
      peerRTT=$(echo "${checkPEER}" | tail -n 1 | cut -d/ -f5 | cut -d. -f1)
      ! isNumber ${peerRTT} && peerRTT=99999 || peerRTTSUM=$((peerRTTSUM + peerRTT))
    else # Incoming connection, ping failed, set as undetermined
      peerRTT=99999
    fi
    lastpeerIP=${peerIP}

    # Update counters
    if [[ ${peerRTT} -lt 50    ]]; then ((peerCNT1++))
    elif [[ ${peerRTT} -lt 100   ]]; then ((peerCNT2++))
    elif [[ ${peerRTT} -lt 200   ]]; then ((peerCNT3++))
    elif [[ ${peerRTT} -lt 99999 ]]; then ((peerCNT4++))
    else ((peerCNT0++)); fi
    rttResults+=( "${peerRTT}:${peerIP}:${peerPORT}" )

    mvPos ${line} ${print_start}
    printf "${style_values_1}%${#peerCNT}s${NC}" "$((++index))"
  done
  mvPos ${line} ${print_start}
  printf "${style_values_2}%${#peerCNT}s${NC}" "${index}"

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

  if [[ ${geoIPquery} != "[]" ]]; then
    geoIPdata="$(curl -s -f http://ip-api.com/batch --data "${geoIPquery}")"
    if [[ -n "${geoIPdata}" ]] || jq -e . <<< "${geoIPdata}" &>/dev/null; then # successfully grabbed
      for entry in $(jq -r '.[] | @base64' <<< "${geoIPdata}"); do
        _jq() { base64 -d <<< ${entry} | jq -r "${1}"; }
        query_ip=$(_jq '.query //empty')
        city=$(_jq '.city // "?"')
        countryCode=$(_jq '.countryCode // "?"')
        geoIP[${query_ip}]="${city}, ${countryCode}"
      done
    fi
  fi
}

#####################################
# Static variables/calculations     #
#####################################
check_peers="false"
show_peers="false"
selected_direction="out"
getNodeMetrics
curr_epoch=${epochnum}
getShelleyTransitionEpoch
if [[ ${SHELLEY_TRANS_EPOCH} -eq -1 ]]; then
  clrScreen
  printf "\n ${style_status_3}Failed${NC} to get shelley transition epoch, calculations will not work correctly!"
  printf "\n\n Possible causes:"
  printf "\n   - Node in startup mode"
  printf "\n   - Shelley era not reached"
  printf "\n After successful node boot or when sync to shelley era has been reached, calculations will be correct\n"
  waitToProceed && clrScreen
fi
version=$("${CNODEBIN}" version)
node_version=$(grep "cardano-node" <<< "${version}" | cut -d ' ' -f2)
node_rev=$(grep "git rev" <<< "${version}" | cut -d ' ' -f3 | cut -c1-8)
cncli_port=$(ss -tnp state established "( dport = :${CNODE_PORT} )" 2>/dev/null | grep cncli | awk '{print $3}' | cut -d: -f2)
fail_count=0
epoch_items_last=0

tput civis # Disable cursor
stty -echo # Disable user input

clrScreen
tlines=$(tput lines) # set initial terminal lines
tcols=$(tput cols)   # set initial terminal columns
printf "${NC}"       # reset and set default color

#####################################
# MAIN LOOP                         #
#####################################
while true; do
  tlines=$(tput lines) # update terminal lines
  tcols=$(tput cols)   # update terminal columns
  [[ ${width} -ge ${tcols} || ${line} -ge $((tlines - 1)) ]] && clrScreen
  while [[ ${width} -ge ${tcols} ]]; do
    mvPos 2 2
    printf "${style_status_3}Terminal width too small!${NC}"
    mvPos 4 2
    printf "Please increase by ${style_info}$(( width - tcols + 1 ))${NC} columns"
    mvPos 6 2
    printf "${style_info}[esc/q] Quit${NC}"
    waitForInput
    tlines=$(tput lines) # update terminal lines
    tcols=$(tput cols)   # update terminal columns
  done
  while [[ ${line} -ge $((tlines - 1)) ]]; do
    mvPos 2 2
    printf "${style_status_3}Terminal height too small!${NC}"
    mvPos 4 2
    printf "Please increase by ${style_info}$(( line - tlines + 2 ))${NC} lines"
    mvPos 6 2
    printf "${style_info}[esc/q] Quit${NC}"
    waitForInput
    tlines=$(tput lines) # update terminal lines
    tcols=$(tput cols)   # update terminal columns
  done

  [[ ${oldLine} != ${line} ]] && oldLine=$line && clrScreen # redraw everything, total height changed

  line=1; mvPos 1 1 # reset position

  # Gather some data
  getNodeMetrics
  mem_rss=$(ps -q ${CNODE_PID} -o rss=) || mem_rss="0"
  [[ ${fail_count} -eq ${RETRIES} ]] && myExit 1 "${style_status_3}COULD NOT CONNECT TO A RUNNING INSTANCE, ${RETRIES} FAILED ATTEMPTS IN A ROW!${NC}"
  if [[ ${nodeStartTime} -le 0 ]]; then
    ((fail_count++))
    clrScreen && mvPos 2 2
    printf "${style_status_3}Connection to node lost, retrying (${fail_count}/${RETRIES})!${NC}"
    waitForInput && continue
  elif [[ ${fail_count} -ne 0 ]]; then # was failed but now ok, re-check
    CNODE_PID=$(pgrep -fn "$(basename ${CNODEBIN}).*.port ${CNODE_PORT}")
    version=$("$(command -v cardano-node)" version)
    node_version=$(grep "cardano-node" <<< "${version}" | cut -d ' ' -f2)
    node_rev=$(grep "git rev" <<< "${version}" | cut -d ' ' -f3 | cut -c1-8)
    cncli_port=$(ss -tnp state established "( dport = :${CNODE_PORT} )" 2>/dev/null | grep cncli | awk '{print $3}' | cut -d: -f2)
    fail_count=0
  fi

  if [[ -z "${PROT_PARAMS}" ]]; then
    PROT_PARAMS="$(${CCLI} query protocol-parameters ${NETWORK_IDENTIFIER} 2>/dev/null)"
    if [[ -n "${PROT_PARAMS}" ]] && ! DECENTRALISATION=$(jq -re .decentralization <<< ${PROT_PARAMS} 2>/dev/null); then DECENTRALISATION=0.5; fi
  fi

  if [[ ${show_peers} = "false" ]]; then
    if [[ ${use_lsof} = 'Y' ]]; then
      peers_in=$(lsof -Pnl +M | grep ESTABLISHED | awk -v pid="${CNODE_PID}" -v port=":${CNODE_PORT}->" '$2 == pid && $9 ~ port {print $9}' | awk -F "->" '{print $2}' | wc -l)
      peers_out=$(lsof -Pnl +M | grep ESTABLISHED | awk -v pid="${CNODE_PID}" -v port=":(${CNODE_PORT}|${EKG_PORT}|${PROM_PORT})->" '$2 == pid && $9 !~ port {print $9}' | awk -F "->" '{print $2}' | wc -l)
    else
      peers_in=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | grep -v ":${cncli_port} " | awk -v port=":${CNODE_PORT}" '$3 ~ port {print}' | wc -l)
      peers_out=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | awk -v port=":(${CNODE_PORT}|${EKG_PORT}|${PROM_PORT})" '$3 !~ port {print}' | wc -l)
    fi
    if [[ ${about_to_lead} -gt 0 ]]; then
      [[ ${nodemode} != "Core" ]] && clrScreen && nodemode="Core"
    else
      [[ ${nodemode} != "Relay" ]] && clrScreen && nodemode="Relay"
    fi
    if [[ ${SHELLEY_TRANS_EPOCH} -eq -1 ]]; then # if Shelley transition epoch calc failed during start, try until successful
      getShelleyTransitionEpoch
      kes_expiration="---"
    else
      kesExpiration
    fi
    if [[ ${curr_epoch} -ne ${epochnum} ]]; then # only update on new epoch to save on processing
      curr_epoch=${epochnum}
      PROT_PARAMS="$(${CCLI} query protocol-parameters ${NETWORK_IDENTIFIER} 2>/dev/null)"
      if [[ -n "${PROT_PARAMS}" ]] && ! DECENTRALISATION=$(jq -re .decentralization <<< ${PROT_PARAMS} 2>/dev/null); then DECENTRALISATION=0.5; fi
    fi
  fi

  header_length=$(( ${#NODE_NAME} + ${#nodemode} + ${#node_version} + ${#node_rev} + ${#NETWORK_NAME} + 19 ))
  [[ ${header_length} -gt ${width} ]] && header_padding=0 || header_padding=$(( (width - header_length) / 2 ))
  printf "%${header_padding}s > ${style_values_2}%s${NC} - ${style_info}(%s - %s)${NC} : ${style_values_1}%s${NC} [${style_values_1}%s${NC}] < \n" "" "${NODE_NAME}" "${nodemode}" "${NETWORK_NAME}" "${node_version}" "${node_rev}" && ((line++))

  ## main section ##
  printf "${tdivider}\n" && ((line++))
  printf "${VL} Uptime: ${style_values_1}%s${NC}" "$(timeLeft ${uptimes})"
  mvPos ${line} $(( width - ${#title} - 2 - ${#CNODE_PORT} - 9 ))
  printf "${VL} Port: ${style_values_2}${CNODE_PORT} "
  mvPos ${line} $(( width - ${#title} - 2 ))
  printf "${VL} ${style_title}${title}" && closeRow
  printf "${m2divider}"
  mvPos ${line} $(( width - ${#title} - 2 - ${#CNODE_PORT} - 9 ))
  printf "${UR}"
  printf "%0.s${HL}" $(seq $(( ${#CNODE_PORT} + 8 )))
  printf "${UHL}"
  printf "%0.s${HL}" $(seq $(( ${#title} + 2 )))
  printf "${LVL}\n" && ((line++))

  if [[ ${check_peers} = "true" ]]; then
    clrLine
    printf "${VL} ${style_info}%-$((width-3))s${NC} ${VL}\n" "Outgoing peer analysis started... please wait!"
    echo "${bdivider}"
    checkPeers out
    # Save values
    peerCNT_out=${peerCNT}; peerCNT0_out=${peerCNT0}; peerCNT1_out=${peerCNT1}; peerCNT2_out=${peerCNT2}; peerCNT3_out=${peerCNT3}; peerCNT4_out=${peerCNT4}
    peerPCT1_out=${peerPCT1}; peerPCT2_out=${peerPCT2}; peerPCT3_out=${peerPCT3}; peerPCT4_out=${peerPCT4}
    peerPCT1items_out=${peerPCT1items}; peerPCT2items_out=${peerPCT2items}; peerPCT3items_out=${peerPCT3items}; peerPCT4items_out=${peerPCT4items}
    peerRTTAVG_out=${peerRTTAVG}; rttResultsSorted_out=${rttResultsSorted}
    peerNbr_start_out=1
    mvPos ${line} 1
    printf "${VL} ${style_info}%-46s${NC}" "Outgoing peer analysis done!" && closeRow

    echo "${m2divider}" && ((line++))

    printf "${VL} ${style_info}%-$((width-3))s${NC} ${VL}\n" "Incoming peer analysis started... please wait!"
    echo "${bdivider}"
    checkPeers in
    # Save values
    peerCNT_in=${peerCNT}; peerCNT0_in=${peerCNT0}; peerCNT1_in=${peerCNT1}; peerCNT2_in=${peerCNT2}; peerCNT3_in=${peerCNT3}; peerCNT4_in=${peerCNT4}
    peerPCT1_in=${peerPCT1}; peerPCT2_in=${peerPCT2}; peerPCT3_in=${peerPCT3}; peerPCT4_in=${peerPCT4}
    peerPCT1items_in=${peerPCT1items}; peerPCT2items_in=${peerPCT2items}; peerPCT3items_in=${peerPCT3items}; peerPCT4items_in=${peerPCT4items}
    peerRTTAVG_in=${peerRTTAVG}; rttResultsSorted_in=${rttResultsSorted}
    peerNbr_start_in=1
    mvPos ${line} 1
    printf "${VL} ${style_info}%-46s${NC}" "Incoming peer analysis done!" && closeRow

    printf -v peer_analysis_date '%(%Y-%m-%d %H:%M:%S)T' -1
    sleep 1
    [[ ${#geoIP[@]} -gt 0 ]] && declare -p geoIP > "$0.geodb"
  elif [[ ${show_peers} = "true" && ${show_peers_info} = "true" ]]; then
    printf "${VL}${STANDOUT} INFO ${NC} One-shot peer analysis last run at ${style_values_1}%s" "${peer_analysis_date}" && closeRow
    printf "${blank_line}\n" && ((line++))
    printf "${VL} Runs a latency test on incoming/outgoing connections to the node." && closeRow
    printf "${VL} Once the analysis is finished, RTTs(Round Trip Time) for each peer" && closeRow
    printf "${VL} is display and grouped in ranges of 0-50, 50-100, 100-200, 200<." && closeRow
    printf "${blank_line}\n" && ((line++))
    printf "${VL} Outgoing connections ping type order(peers in own topology):" && closeRow
    printf "${VL} 1. ${style_values_2}cncli${NC} - If available, this gives the most accurate measure as" && closeRow
    printf "${VL}    it checks the entire handshake process against the remote peer." && closeRow
    printf "${VL} 2. ${style_values_2}ss${NC} - Sends a TCP SYN package to ping the remote peer on" && closeRow
    printf "${VL}    the cardano-node port. Should give ~100%% success rate." && closeRow
    printf "${VL} 3. ${style_values_2}tcptraceroute${NC} - Same as ss" && closeRow
    printf "${VL} 4. ${style_values_2}ping${NC} - fallback method using ICMP ping against IP." && closeRow
    printf "${VL}    Only work if the FW of remote peer accepts ICMP traffic." && closeRow
    printf "${blank_line}\n" && ((line++))
    printf "${VL} For incoming connections, only ICMP ping is used as remote peer port" && closeRow
    printf "${VL} is unknown. It's not uncommon to see many undetermined peers for" && closeRow
    printf "${VL} incoming connections as it's a good security practice to disable" && closeRow
    printf "${VL} ICMP in firewall." && closeRow
  elif [[ ${show_peers} = "true" ]]; then
    printf "${VL}${STANDOUT} OUT ${NC}  RTT : Peers / Percent" && closeRow

    printf "${VL}    0-50ms : ${style_values_1}%5s${NC}   ${style_values_1}%.f${NC}%% ${style_status_1}" "${peerCNT1_out}" "${peerPCT1_out}"
    mvPos ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT1items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    closeRow

    printf "${VL}  50-100ms : ${style_values_1}%5s${NC}   ${style_values_1}%.f${NC}%% ${style_status_2}" "${peerCNT2_out}" "${peerPCT2_out}"
    mvPos ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT2items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    closeRow

    printf "${VL} 100-200ms : ${style_values_1}%5s${NC}   ${style_values_1}%.f${NC}%% ${style_status_3}" "${peerCNT3_out}" "${peerPCT3_out}"
    mvPos ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT3items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    closeRow

    printf "${VL}   200ms < : ${style_values_1}%5s${NC}   ${style_values_1}%.f${NC}%% ${style_status_4}" "${peerCNT4_out}" "${peerPCT4_out}"
    mvPos ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT4items_out} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    closeRow

    echo "${m3divider}" && ((line++))

    printf "${VL} Total / Undetermined : ${style_values_1}%s${NC} / " "${peerCNT_out}"
    [[ ${peerCNT0_out} -eq 0 ]] && printf "${style_values_1}0${NC}" || printf "${style_values_4}%s${NC}" "${peerCNT0_out}"
    mvPos ${line} $((two_col_second + 1))
    if [[ ${peerRTTAVG_out} -ge 200 ]]; then printf "Average RTT : ${style_status_4}%s${NC} ms" "${peerRTTAVG_out}"
    elif [[ ${peerRTTAVG_out} -ge 100 ]]; then printf "Average RTT : ${style_status_3}%s${NC} ms" "${peerRTTAVG_out}"
    elif [[ ${peerRTTAVG_out} -ge 50  ]]; then printf "Average RTT : ${style_status_2}%s${NC} ms" "${peerRTTAVG_out}"
    elif [[ ${peerRTTAVG_out} -ge 0   ]]; then printf "Average RTT : ${style_status_1}%s${NC} ms" "${peerRTTAVG_out}"
    else printf "Average RTT : ${style_status_3}---${NC} ms"; fi
    closeRow

    if [[ -n ${rttResultsSorted_out} ]]; then
      echo "${m3divider}" && ((line++))

      printf "${VL}${style_info}   #  %21s  RTT    Geolocation${NC}\n" "REMOTE PEER"
      header_line=$((line++))

      peerNbr_out=0
      peerLocationWidth=$((width-38))
      for peer in ${rttResultsSorted_out}; do
        ((peerNbr_out++))
        [[ ${peerNbr_out} -lt ${peerNbr_start_out} ]] && continue
        peerRTT=$(echo ${peer} | cut -d: -f1)
        peerIP=$(echo ${peer} | cut -d: -f2)
        peerPORT=$(echo ${peer} | cut -d: -f3)
        IFS=',' read -ra peerLocation <<< "${geoIP[${peerIP}]}"
        if isPrivateIP ${peerIP}; then
          peerLocationFmt="(Private IP)"
        elif [[ ${#peerLocation[@]} -eq 2 ]]; then
          peerLocationCity="${peerLocation[0]}"
          peerLocationCC="${peerLocation[1]}"
          [[ ${#peerLocationCity} -gt $((peerLocationWidth-4)) ]] && peerLocationCity="${peerLocationCity:0:$((peerLocationWidth-6))}.."
          peerLocationFmt="${peerLocationCity},${peerLocationCC}"
        else
          peerLocationFmt="Unknown location"
        fi
          if [[ ${peerRTT} -lt 50    ]]; then printf "${VL} %3s  %15s:%-5s  ${style_status_1}%-5s${NC}  ${style_values_4}%s" "${peerNbr_out}" "${peerIP}" "${peerPORT}" "${peerRTT}" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"
        elif [[ ${peerRTT} -lt 100   ]]; then printf "${VL} %3s  %15s:%-5s  ${style_status_2}%-5s${NC}  ${style_values_4}%s" "${peerNbr_out}" "${peerIP}" "${peerPORT}" "${peerRTT}" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"
        elif [[ ${peerRTT} -lt 200   ]]; then printf "${VL} %3s  %15s:%-5s  ${style_status_3}%-5s${NC}  ${style_values_4}%s" "${peerNbr_out}" "${peerIP}" "${peerPORT}" "${peerRTT}" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"
        elif [[ ${peerRTT} -lt 99999 ]]; then printf "${VL} %3s  %15s:%-5s  ${style_status_4}%-5s${NC}  ${style_values_4}%s" "${peerNbr_out}" "${peerIP}" "${peerPORT}" "${peerRTT}" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"
        else printf "${VL} %3s  %15s:%-5s  %-5s  ${style_values_4}%s" "${peerNbr_out}" "${peerIP}" "${peerPORT}" "---" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"; fi
        closeRow
        [[ ${peerNbr_out} -eq $((peerNbr_start_out+PEER_LIST_CNT-1)) ]] && break
      done

      [[ ${peerNbr_start_out} -gt 1 ]] && nav_str="< " || nav_str=""
      nav_str+="[${peerNbr_start_out}-${peerNbr_out}]"
      [[ ${peerCNT_out} -gt ${peerNbr_out} ]] && nav_str+=" >"
      mvPos ${header_line} $((width-${#nav_str}-2))
      [[ ${selected_direction} = "out" ]] && printf "${style_values_3} %s ${NC} ${VL}\n" "${nav_str}" || printf "  %s ${VL}\n" "${nav_str}"
      mvPos ${line} 1
    fi

    echo "${mdivider}" && ((line++))

    printf "${VL}${STANDOUT} In ${NC}   RTT : Peers / Percent"
    closeRow

    printf "${VL}    0-50ms : ${style_values_1}%5s${NC}   ${style_values_1}%.f${NC}%% ${style_status_1}" "${peerCNT1_in}" "${peerPCT1_in}"
    mvPos ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT1items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    closeRow

    printf "${VL}  50-100ms : ${style_values_1}%5s${NC}   ${style_values_1}%.f${NC}%% ${style_status_2}" "${peerCNT2_in}" "${peerPCT2_in}"
    mvPos ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT2items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    closeRow

    printf "${VL} 100-200ms : ${style_values_1}%5s${NC}   ${style_values_1}%.f${NC}%% ${style_status_3}" "${peerCNT3_in}" "${peerPCT3_in}"
    mvPos ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT3items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    closeRow

    printf "${VL}   200ms < : ${style_values_1}%5s${NC}   ${style_values_1}%.f${NC}%% ${style_status_4}" "${peerCNT4_in}" "${peerPCT4_in}"
    mvPos ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT4items_in} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    closeRow

    echo "${m3divider}" && ((line++))

    printf "${VL} Total / Undetermined : ${style_values_1}%s${NC} / " "${peerCNT_in}"
    [[ ${peerCNT0_in} -eq 0 ]] && printf "${style_values_1}0${NC}" || printf "${style_values_4}%s${NC}" "${peerCNT0_in}"
    mvPos ${line} $((two_col_second + 1))
    if [[ ${peerRTTAVG_in} -ge 200 ]]; then printf "Average RTT : ${style_status_4}%s${NC} ms" "${peerRTTAVG_in}"
    elif [[ ${peerRTTAVG_in} -ge 100 ]]; then printf "Average RTT : ${style_status_3}%s${NC} ms" "${peerRTTAVG_in}"
    elif [[ ${peerRTTAVG_in} -ge 50  ]]; then printf "Average RTT : ${style_status_2}%s${NC} ms" "${peerRTTAVG_in}"
    elif [[ ${peerRTTAVG_in} -ge 0   ]]; then printf "Average RTT : ${style_status_1}%s${NC} ms" "${peerRTTAVG_in}"
    else printf "Average RTT : ${style_status_3}---${NC} ms"; fi
    closeRow

    if [[ -n ${rttResultsSorted_in} ]]; then
      echo "${m3divider}" && ((line++))

      printf "${VL}${style_info}   #  %21s  RTT    Geolocation${NC}\n" "REMOTE PEER"
      header_line=$((line++))

      peerNbr_in=0
      peerLocationWidth=$((width-38))
      for peer in ${rttResultsSorted_in}; do
        ((peerNbr_in++))
        [[ ${peerNbr_in} -lt ${peerNbr_start_in} ]] && continue
        peerRTT=$(echo ${peer} | cut -d: -f1)
        peerIP=$(echo ${peer} | cut -d: -f2)
        peerPORT=$(echo ${peer} | cut -d: -f3)
        IFS=',' read -ra peerLocation <<< "${geoIP[${peerIP}]}"
        if isPrivateIP ${peerIP}; then
          peerLocationFmt="(Private IP)"
        elif [[ ${#peerLocation[@]} -eq 2 ]]; then
          peerLocationCity="${peerLocation[0]}"
          peerLocationCC="${peerLocation[1]}"
          [[ ${#peerLocationCity} -gt $((peerLocationWidth-4)) ]] && peerLocationCity="${peerLocationCity:0:$((peerLocationWidth-6))}.."
          peerLocationFmt="${peerLocationCity},${peerLocationCC}"
        else
          peerLocationFmt="Unknown location"
        fi
          if [[ ${peerRTT} -lt 50    ]]; then printf "${VL} %3s  %15s:%-5s  ${style_status_1}%-5s${NC}  ${style_values_4}%s" "${peerNbr_in}" "${peerIP}" "${peerPORT}" "${peerRTT}" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"
        elif [[ ${peerRTT} -lt 100   ]]; then printf "${VL} %3s  %15s:%-5s  ${style_status_2}%-5s${NC}  ${style_values_4}%s" "${peerNbr_in}" "${peerIP}" "${peerPORT}" "${peerRTT}" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"
        elif [[ ${peerRTT} -lt 200   ]]; then printf "${VL} %3s  %15s:%-5s  ${style_status_3}%-5s${NC}  ${style_values_4}%s" "${peerNbr_in}" "${peerIP}" "${peerPORT}" "${peerRTT}" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"
        elif [[ ${peerRTT} -lt 99999 ]]; then printf "${VL} %3s  %15s:%-5s  ${style_status_4}%-5s${NC}  ${style_values_4}%s" "${peerNbr_in}" "${peerIP}" "${peerPORT}" "${peerRTT}" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"
        else printf "${VL} %3s  %15s:%-5s  %-5s  ${style_values_4}%s" "${peerNbr_in}" "${peerIP}" "${peerPORT}" "---" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"; fi
        closeRow
        [[ ${peerNbr_in} -eq $((peerNbr_start_in+PEER_LIST_CNT-1)) ]] && break
      done

      [[ ${peerNbr_start_in} -gt 1 ]] && nav_str="< " || nav_str=""
      nav_str+="[${peerNbr_start_in}-${peerNbr_in}]"
      [[ ${peerCNT_in} -gt ${peerNbr_in} ]] && nav_str+=" >"
      mvPos ${header_line} $((width-${#nav_str}-2))
      [[ ${selected_direction} = "in" ]] && printf "${style_values_3} %s ${NC} ${VL}\n" "${nav_str}" || printf "  %s ${VL}\n" "${nav_str}"
      mvPos ${line} 1
    fi
  elif [[ ${show_home_info} = "true" ]]; then
    printf "${VL}${STANDOUT} INFO ${NC} Displays live metrics gathered from node EKG endpoint" && closeRow
    printf "${blank_line}\n" && ((line++))
    printf "${VL} ${style_values_2}Upper Main Section${NC}" && closeRow
    printf "${VL} Epoch number & progress is live from node while calculation of date" && closeRow
    printf "${VL} until epoch boundary is based on genesis parameters. Reference tip" && closeRow
    printf "${VL} is also a calculation based on genesis values used to compare" && closeRow
    printf "${VL} against the node tip to see how far of the tip(diff value) the node" && closeRow
    printf "${VL} is. This interval is dynamic and based on different genesis" && closeRow
    printf "${VL} parameters. In/Out peers show how many connections the node have" && closeRow
    printf "${VL} established in and out. Live/Heap shows the memory utilization of" && closeRow
    printf "${VL} live/heap data." && closeRow
    printf "${blank_line}\n" && ((line++))
    printf "${VL} ${style_values_2}Core section${NC}" && closeRow
    printf "${VL} If the node is run as a block producer, a second section is" && closeRow
    printf "${VL} displayed that contain KES key and slot/block stats. When close to" && closeRow
    printf "${VL} the expire date the values will change color." && closeRow
    printf "${blank_line}\n" && ((line++))
    printf "${VL} A leadership check is performed for each slot. Slots can be missed" && closeRow
    printf "${VL} if the node is busy and can't keep up (e.g., due to GC pauses)." && closeRow
    printf "${VL} A large number of missed slots needs further study." && closeRow
    printf "${blank_line}\n" && ((line++))
    printf "${VL} If CNCLI is activated to calculate and store node blocks, data from" && closeRow
    printf "${VL} this blocklog DB is displayed, which includes a timer and progress" && closeRow
    printf "${VL} bar counting down until next slot leader. The progress bar color" && closeRow
    printf "${VL} indicates the time range. Green is 1 epoch, Tan is 1 day, red is 1" && closeRow
    printf "${VL} hour, Magenta is 5 minutes. If CNCLI is not activated blocks created" && closeRow
    printf "${VL} is taken from EKG metrics." && closeRow
    printf "${blank_line}\n" && ((line++))
    printf "${VL} - Leader    : scheduled to make block at this slot" && closeRow
    printf "${VL} - Ideal     : Expected/Ideal number of blocks assigned" && closeRow
    printf "${VL}               based on active stake (sigma)" && closeRow
    printf "${VL} - Luck      : Leader slots assigned vs Ideal slots" && closeRow
    printf "${VL} - Adopted   : block created successfully" && closeRow
    printf "${VL} - Confirmed : block created validated to be on-chain" && closeRow
    printf "${VL} - Invalid   : node failed to create block" && closeRow
    printf "${VL} - Missed    : scheduled at slot but no record of it in " && closeRow
    printf "${VL}               cncli DB and no other pool has made a block" && closeRow
    printf "${VL}               for this slot" && closeRow
    printf "${VL} - Ghosted   : block created but marked as orphaned and no" && closeRow
    printf "${VL}               other pool has made a valid block for this" && closeRow
    printf "${VL}               slot, height battle or block propagation issue" && closeRow
    printf "${VL} - Stolen    : another pool has a valid block registered" && closeRow
    printf "${VL}               on-chain for the same slot" && closeRow
  else
    if [[ ${epochnum} -ge ${SHELLEY_TRANS_EPOCH} ]]; then
      epoch_progress=$(echo "(${slot_in_epoch}/${EPOCH_LENGTH})*100" | bc -l)        # in Shelley era or Shelley only TestNet
    else
      epoch_progress=$(echo "(${slot_in_epoch}/${BYRON_EPOCH_LENGTH})*100" | bc -l)  # in Byron era
    fi
    epoch_progress_1dec=$(printf "%2.1f" "${epoch_progress}")
    epoch_time_left=$(timeLeft "$(timeUntilNextEpoch)")
    printf "${VL} Epoch ${style_values_1}%s${NC} [${style_values_1}%s%%${NC}], ${style_values_1}%s${NC} %-12s" "${epochnum}" "${epoch_progress_1dec}" "${epoch_time_left}" "remaining"
    closeRow
    
    epoch_items=$(( $(printf %.0f "${epoch_progress}") * granularity / 100 ))
    if [[ -z ${epoch_bar} || ${epoch_items} -ne ${epoch_items_last} ]]; then
      epoch_bar=""; epoch_items_last=${epoch_items}
      for i in $(seq 0 $((granularity-1))); do
        [[ $i -lt ${epoch_items} ]] && epoch_bar+=$(printf "${char_marked}") || epoch_bar+=$(printf "${NC}${char_unmarked}")
      done
    fi
    printf "${VL} ${style_values_1}${epoch_bar}${NC} ${VL}\n"; ((line++))

    printf "${blank_line}\n" && ((line++))

    tip_ref=$(getSlotTipRef)
    tip_diff=$(( tip_ref - slotnum ))
    
    # row 1 - three col view
    printf "${VL} Block      : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${blocknum}"
    mvThreeSecond
    printf "Tip (ref)  : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${tip_ref}"
    mvThreeThird
    printf -v mem_rss_gb "%.1f" "$(bc -l <<<"(${mem_rss}/1048576)")"
    printf "Mem (RSS)  : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#mem_rss_gb}))s" "${mem_rss_gb}" "G"
    closeRow
    
    # row 2
    printf "${VL} Slot       : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${slot_in_epoch}"
    mvThreeSecond
    printf "Tip (node) : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${slotnum}"
    mvThreeThird
    printf -v mem_live_gb "%.1f" "$(bc -l <<<"(${mem_live}/1073741824)")"
    printf "Mem (Live) : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#mem_live_gb}))s" "${mem_live_gb}" "G"
    closeRow
    
    # row 3
    printf "${VL} Density    : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${density}"
    mvThreeSecond
    if [[ ${slotnum} -eq 0 ]]; then
      printf "Status     : ${style_info}%-${three_col_2_value_width}s${NC}" "starting"
    elif [[ ${SHELLEY_TRANS_EPOCH} -eq -1 ]]; then
      printf "Status     : ${style_info}%-${three_col_2_value_width}s${NC}" "syncing"
    elif [[ ${tip_diff} -le $(slotInterval) ]]; then
      printf "Tip (diff) : ${style_status_1}%-${three_col_2_value_width}s${NC}" "${tip_diff} :)"
    elif [[ ${tip_diff} -le $(( $(slotInterval) * 4 )) ]]; then
      printf "Tip (diff) : ${style_status_2}%-${three_col_2_value_width}s${NC}" "${tip_diff} :|"
    else
      sync_progress=$(echo "(${slotnum}/${tip_ref})*100" | bc -l)
      printf "Status     : ${style_info}%-${three_col_2_value_width}s${NC}" "sync $(printf "%2.1f" "${sync_progress}")%"
    fi
    mvThreeThird
    printf -v mem_heap_gb "%.1f" "$(bc -l <<<"(${mem_heap}/1073741824)")"
    printf "Mem (Heap) : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#mem_heap_gb}))s" "${mem_heap_gb}" "G"
    closeRow

    # row 4
    printf "${VL} Total Tx   : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${tx_processed}"
    mvThreeSecond
    printf "Peers In   : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${peers_in}"
    mvThreeThird
    printf "GC Minor   : ${style_values_1}%-${three_col_3_value_width}s${NC}" "${gc_minor}"
    closeRow

    # row 5
    mempool_tx_bytes=$((mempool_bytes/1024))
    printf "${VL} Pending Tx : ${style_values_1}%s${NC}/${style_values_1}%s${NC}%-$((three_col_1_value_width - ${#mempool_tx} - ${#mempool_tx_bytes} - 3))s" "${mempool_tx}" "${mempool_tx_bytes}" "K"
    mvThreeSecond
    printf "Peers Out  : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${peers_out}"
    mvThreeThird
    printf "GC Major   : ${style_values_1}%-${three_col_3_value_width}s${NC}" "${gc_major}"
    closeRow

    ## Core section ##
    if [[ ${nodemode} = "Core" ]]; then
      echo "${coredivider}" && ((line++))

      printf "${VL} KES current/remaining"
      mvTwoSecond 
      printf ": ${style_values_1}%s${NC} / " "${kesperiod}"
      if [[ ${remaining_kes_periods} -le 0 ]]; then
        printf "${style_status_4}%s${NC}" "${remaining_kes_periods}"
      elif [[ ${remaining_kes_periods} -le 8 ]]; then
        printf "${style_status_3}%s${NC}" "${remaining_kes_periods}"
      else
        printf "${style_values_1}%s${NC}" "${remaining_kes_periods}"
      fi
      closeRow
      
      printf "${VL} KES expiration date"
      mvTwoSecond
      printf ": ${style_values_1}%-${two_col_width}s${NC}" "${kes_expiration}" && closeRow
      
      printf "${VL} Missed slot leader checks"
      mvTwoSecond
      printf -v missed_slots_pct "%.4f" "$(bc -l <<<"(${missed_slots}/(${about_to_lead}+${missed_slots}))*100")"
      printf ": ${style_values_1}%s${NC} (${style_values_1}%s${NC} %%)" "${missed_slots}" "${missed_slots_pct}" && closeRow

      printf "${blockdivider}\n" && ((line++))

      if [[ -f "${BLOCKLOG_DB}" ]]; then
        invalid_cnt=0; missed_cnt=0; ghosted_cnt=0; stolen_cnt=0; confirmed_cnt=0; adopted_cnt=0; leader_cnt=0
        for status_type in $(sqlite3 "${BLOCKLOG_DB}" "SELECT status, COUNT(status) FROM blocklog WHERE epoch=${epochnum} GROUP BY status;" 2>/dev/null); do
          IFS='|' read -ra status <<< ${status_type}
          case ${status[0]} in
            invalid) invalid_cnt=${status[1]} ;;
            missed) missed_cnt=${status[1]} ;;
            ghosted) ghosted_cnt=${status[1]} ;;
            stolen) stolen_cnt=${status[1]} ;;
            confirmed) confirmed_cnt=${status[1]} ;;
            adopted) adopted_cnt=${status[1]} ;;
            leader) leader_cnt=${status[1]} ;;
          esac
        done
        adopted_cnt=$(( adopted_cnt + confirmed_cnt ))
        leader_cnt=$(( leader_cnt + adopted_cnt + invalid_cnt + missed_cnt + ghosted_cnt + stolen_cnt ))
        leader_next=$(sqlite3 "${BLOCKLOG_DB}" "SELECT at FROM blocklog WHERE datetime(at) > datetime('now') ORDER BY slot ASC LIMIT 1;" 2>/dev/null)
        IFS='|' read -ra epoch_stats <<< "$(sqlite3 "${BLOCKLOG_DB}" "SELECT epoch_slots_ideal, max_performance FROM epochdata WHERE epoch=${epochnum};" 2>/dev/null)"
        if [[ ${#epoch_stats[@]} -eq 0 ]]; then epoch_stats=("-" "-"); else epoch_stats[1]="${epoch_stats[1]}%"; fi

        [[ ${invalid_cnt} -eq 0 ]] && invalid_fmt="${style_values_1}" || invalid_fmt="${style_status_3}"
        [[ ${missed_cnt} -eq 0 ]] && missed_fmt="${style_values_1}" || missed_fmt="${style_status_3}"
        [[ ${ghosted_cnt} -eq 0 ]] && ghosted_fmt="${style_values_1}" || ghosted_fmt="${style_status_3}"
        [[ ${stolen_cnt} -eq 0 ]] && stolen_fmt="${style_values_1}" || stolen_fmt="${style_status_3}"
        [[ ${confirmed_cnt} -ne ${adopted_cnt} ]] && confirmed_fmt="${style_status_2}" || confirmed_fmt="${style_values_2}"
        
        # row 1
        printf "${VL} Leader     : ${style_values_1}%-${col_block_1_1_value_width}s${NC}" "${leader_cnt}"
        mvThreeSecond
        printf "Adopted    : ${style_values_1}%-${col_block_1_2_value_width}s${NC}" "${adopted_cnt}"
        mvThreeThird
        printf "Missed     : ${missed_fmt}%-${col_block_1_3_value_width}s${NC}" "${missed_cnt}"
        closeRow
        
        # row 2
        printf "${VL} Ideal      : ${style_values_1}%-${col_block_1_1_value_width}s${NC}" "${epoch_stats[0]}"
        mvThreeSecond
        printf "Confirmed  : ${confirmed_fmt}%-${col_block_1_2_value_width}s${NC}" "${confirmed_cnt}"
        mvThreeThird
        printf "Ghosted    : ${ghosted_fmt}%-${col_block_1_3_value_width}s${NC}" "${ghosted_cnt}"
        closeRow
        
        # row 3
        printf "${VL} Luck       : ${style_values_1}%-${col_block_1_1_value_width}s${NC}" "${epoch_stats[1]}"
        mvThreeSecond
        printf "Invalid    : ${invalid_fmt}%-${col_block_1_2_value_width}s${NC}" "${invalid_cnt}"
        mvThreeThird
        printf "Stolen     : ${stolen_fmt}%-${col_block_1_3_value_width}s${NC}" "${stolen_cnt}"
        closeRow

        if [[ -n ${leader_next} ]]; then
          leader_time_left=$((  $(date -u -d ${leader_next} +%s) - $(printf '%(%s)T\n' -1) ))
          if [[ ${leader_time_left} -gt 0 ]]; then
            setSizeAndStyleOfProgressBar ${leader_time_left}
            leader_time_left_fmt="$(timeLeft ${leader_time_left})"
            leader_progress=$(echo "(1-(${leader_time_left}/${leader_bar_span}))*100" | bc -l)
            leader_items=$(( ($(printf %.0f "${leader_progress}") * granularity) / 100 ))
            printf "${m3divider}\n" && ((line++))
            printf "${VL} ${style_values_1}%s${NC} until leader " "${leader_time_left_fmt}" && closeRow
            if [[ -z ${leader_bar} || ${leader_items} -ne ${leader_items_last} ]]; then
              leader_bar=""; leader_items_last=${leader_items}
              for i in $(seq 0 $((granularity-1))); do
                [[ $i -lt ${leader_items} ]] && leader_bar+=$(printf "${leader_bar_style}${char_marked}") || leader_bar+=$(printf "${NC}${char_unmarked}")
              done
            fi
            printf "${VL} ${leader_bar}" && closeRow
          fi
        fi
      else
        [[ ${isleader} -ne ${adopted} ]] && adopted_fmt="${style_status_2}" || adopted_fmt="${style_values_2}"
        [[ ${didntadopt} -eq 0 ]] && invalid_fmt="${style_values_1}" || invalid_fmt="${style_status_3}"
        
        printf "${VL} Leader : ${style_values_1}%-${col_block_2_1_value_width}s${NC}" "${isleader}"
        mvThreeSecond
        printf "Adopted : ${adopted_fmt}%-${col_block_2_2_value_width}s${NC}" "${adopted}"
        mvThreeThird
        printf "Invalid : ${invalid_fmt}%-${col_block_2_3_value_width}s${NC}" "${didntadopt}"
        closeRow
      fi
    fi
  fi

  [[ ${check_peers} = "true" ]] && check_peers=false && show_peers=true && clrScreen && continue

  echo "${bdivider}" && ((line++))
  printf " TG Announcement/Support channel: ${style_info}t.me/guild_operators_official${NC}\n\n" && line=$((line+2))

  [[ -z ${oldLine} ]] && oldLine=$line
  
  if [[ ${show_peers} = "true" && ${show_peers_info} = "true" ]]; then
    printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[b] Back to Peer Analysis${NC}"
    clrLine
    waitForInput "peersInfo"
  elif [[ ${show_peers} = "true" ]]; then
    printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[h] Home${NC} | ${style_info}[i] Info${NC} | Up/Down    : Select List\n%38s%s" "" "Left/Right : Navigate List"
    clrLine
    waitForInput "peers"
  elif [[ ${show_home_info} = "true" ]]; then
    printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[h] Home${NC}"
    clrLine
    waitForInput "homeInfo"
  else
    printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[i] Info${NC} | ${style_info}[p] Peer Analysis${NC}"
    clrLine
    waitForInput
  fi
done
