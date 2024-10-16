#!/usr/bin/env bash
#shellcheck disable=SC2009,SC2034,SC2059,SC2206,SC2086,SC2015,SC2154
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#NODE_NAME="Cardano Node"                 # Change your node's name prefix here, keep at or below 19 characters!
#REFRESH_RATE=2                           # How often (in seconds) to refresh the view (additional time for processing and output may slow it down)
#REPAINT_RATE=10                          # Re-paint entire screen every nth REFRESH_RATE. Complete re-paint can make screen flicker, hence not done for every update
#LEGACY_MODE=false                        # (true|false) If enabled unicode box-drawing characters will be replaced by standard ASCII characters
#RETRIES=3                                # How many attempts to connect to running Cardano node before erroring out and quitting (0 for continuous retries)
#PEER_LIST_CNT=10                         # Number of peers to show on each in/out page in peer analysis view
#THEME="dark"                             # dark  = suited for terminals with a dark background
                                          # light = suited for terminals with a bright background
#ENABLE_IP_GEOLOCATION=Y                  # Enable IP geolocation on outgoing and incoming connections using ip-api.com (default: Y)
#LATENCY_TOOLS="cncli|ss|tcptraceroute|ping" # Preferred latency check tool order, valid entries: cncli|ss|tcptraceroute|ping (must be separated by |)
#CNCLI_CONNECT_ONLY=false                 # By default cncli measure full connect handshake duration. If set to false, only connect is measured similar to other tools
#HIDE_DUPLICATE_IPS=N                     # If set to 'Y', duplicate and local IP's will be filtered out in peer analysis, else all connected peers are shown (default: N)
#VERBOSE=N                                # Start in verbose mode showing additional metrics (default: N)
#GLV_LOG="${LOG_DIR}/gLiveView.log"       # Log gLiveView errors, set empty to disable. LOG_DIR set in env file.

#####################################
# Themes                            #
#####################################

setTheme() {
  if [[ -z ${THEME} || ${THEME} = "dark" ]]; then
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

GLV_VERSION=v1.30.4

PARENT="$(dirname $0)"

usage() {
  cat <<-EOF
		Usage: $(basename "$0") [-l] [-p] [-b <branch name>] [-v]
		Koios gLiveView - A local Cardano node monitoring tool

		-l    Activate legacy mode - standard ASCII characters instead of box-drawing characters
		-u    Skip script update check overriding UPDATE_CHECK value in env
		-b    Use alternate branch to check for updates - only for testing/development (Default: Master)
		-v    Print Koios gLiveView version
		EOF
  exit 1
}

SKIP_UPDATE=N

while getopts :lub:v opt; do
  case ${opt} in
    l ) LEGACY_MODE="true" ;;
    u ) SKIP_UPDATE=Y ;;
    b ) echo "${OPTARG}" > "${PARENT}"/.env_branch ;;
    v ) echo -e "\nKoios gLiveView ${GLV_VERSION} (branch: $([[ -f "${PARENT}"/.env_branch ]] && cat "${PARENT}"/.env_branch || echo "master"))\n"; exit 0 ;;
    \? ) usage ;;
  esac
done
shift $((OPTIND -1))

# General exit handler
cleanup() {
  [[ -n $1 ]] && err=$1 || err=$?
  [[ $err -eq 0 ]] && clear
  tput cnorm # restore cursor
  [[ -n ${exit_msg} ]] && echo -e "\n${exit_msg}\n" || echo -e "\nKoios gLiveView terminated, cleaning up...\n"
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
  echo -e "This is a mandatory prerequisite, please install with guild-deploy.sh or manually download from GitHub\n"
  myExit 1
fi

. "${PARENT}"/env &>/dev/null # ignore any errors, re-sourced later

if [[ ${UPDATE_CHECK} = Y && ${SKIP_UPDATE} != Y ]]; then

  if command -v cncli >/dev/null && command -v systemctl >/dev/null && systemctl is-active --quiet ${CNODE_VNAME}-cncli-sync.service 2>/dev/null; then
    vcur=$(cncli -V | awk '{print $2}')
    vrem=$(curl -s https://api.github.com/repos/${G_ACCOUNT}/cncli/releases/latest | jq -r .tag_name)
    [[ "${vcur}" != "${vrem}" ]] && printf "${FG_MAGENTA}CNCLI current version (${vcur}) different from repo (${vrem}), consider upgrading!.${NC}" && waitToProceed
  fi

  echo "Checking for script updates..."
  # Check availability of checkUpdate function
  if [[ ! $(command -v checkUpdate) ]]; then
    echo -e "\nCould not find checkUpdate function in env, make sure you're using official docos for installation!"
    myExit 1
  fi

  # check for env update
  ENV_UPDATED=N
  checkUpdate "${PARENT}"/env N N N
  case $? in
    1) ENV_UPDATED=Y ;;
    2) myExit 1 ;;
  esac

  # source common env variables in case it was updated
  . "${PARENT}"/env
  case $? in
    1) myExit 1 "ERROR: gLiveView failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" ;;
    2) clear ;;
  esac

  # check for gLV update
  checkUpdate "${PARENT}"/gLiveView.sh "${ENV_UPDATED}"
  case $? in
    1) $0 "$@" "-u"; myExit 0 ;; # re-launch script with same args skipping update check
    2) exit 1 ;;
  esac
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

[[ -z ${NODE_NAME} ]] && NODE_NAME="Cardano Node"
[[ ${#NODE_NAME} -gt 19 ]] && myExit 1 "Please keep node name at or below 19 characters in length!"

[[ -z ${REFRESH_RATE} ]] && REFRESH_RATE=2
[[ ! ${REFRESH_RATE} =~ ^[0-9]+$ ]] && myExit 1 "Please set a valid refresh rate number!"

[[ -z ${REPAINT_RATE} ]] && REPAINT_RATE=10
[[ ! ${REPAINT_RATE} =~ ^[0-9]+$ ]] && myExit 1 "Please set a valid repaint rate number!"

[[ -z ${LEGACY_MODE} ]] && LEGACY_MODE=false

[[ -z "${RETRIES}" ]]  && RETRIES=3

[[ -z ${ENABLE_IP_GEOLOCATION} ]] && ENABLE_IP_GEOLOCATION=Y
declare -gA geoIP=()
[[ -f "$0.geodb" ]] && . -- "$0.geodb"

[[ -z ${PEER_LIST_CNT} ]] && PEER_LIST_CNT=10

[[ -z ${LATENCY_TOOLS} ]] && LATENCY_TOOLS="cncli|ss|tcptraceroute|ping"

[[ -z ${CNCLI_CONNECT_ONLY} ]] && CNCLI_CONNECT_ONLY=false

[[ -z ${HIDE_DUPLICATE_IPS} ]] && HIDE_DUPLICATE_IPS=N

[[ -z ${VERBOSE} ]] && VERBOSE=N

[[ -z ${GLV_LOG} ]] && GLV_LOG="${LOG_DIR}/gLiveView.log"

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
title="Koios gLiveView ${GLV_VERSION}"

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
  conndivider=$(printf "${NC}|- ${style_info}CONNECTIONS${NC} " && printf "%0.s-" $(seq $((width-15))) && printf "|")
  propdivider=$(printf "${NC}|- ${style_info}BLOCK PROPAGATION${NC} " && printf "%0.s-" $(seq $((width-21))) && printf "|")
  resourcesdivider=$(printf "${NC}|- ${style_info}NODE RESOURCE USAGE${NC} " && printf "%0.s-" $(seq $((width-23))) && printf "|")
  blockdivider=$(printf "${NC}|- ${style_info}BLOCK PRODUCTION${NC} " && printf "%0.s-" $(seq $((width-20))) && printf "|")
  mithrildivider=$(printf "${NC}|- ${style_info}MITHRIL SIGNER${NC} " && printf "%0.s-" $(seq $((width-18))) && printf "|")
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
  conndivider=$(printf "${NC}\\u2502- ${style_info}CONNECTIONS${NC} " && printf "%0.s-" $(seq $((width-15))) && printf "\\u2502")
  propdivider=$(printf "${NC}\\u2502- ${style_info}BLOCK PROPAGATION${NC} " && printf "%0.s-" $(seq $((width-21))) && printf "\\u2502")
  resourcesdivider=$(printf "${NC}\\u2502- ${style_info}NODE RESOURCE USAGE${NC} " && printf "%0.s-" $(seq $((width-23))) && printf "\\u2502")
  blockdivider=$(printf "${NC}\\u2502- ${style_info}BLOCK PRODUCTION${NC} " && printf "%0.s-" $(seq $((width-20))) && printf "\\u2502")
  mithrildivider=$(printf "${NC}\\u2502- ${style_info}MITHRIL SIGNER${NC} " && printf "%0.s-" $(seq $((width-18))) && printf "\\u2502")
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
  [[ ${key1} = "q" ]] && myExit 0 "Koios gLiveView stopped!"
  [[ ${key1} = "${ESC}" && ${key2} = "" ]] && myExit 0 "Koios gLiveView stopped!"
  if [[ $# -eq 0 ]]; then
    [[ ${key1} = "p" ]] && check_peers="true" && clrScreen && return
    [[ ${key1} = "i" ]] && show_home_info="true" && clrScreen && return
    if [[ ${key1} = "v" ]]; then [[ ${VERBOSE} = "N" ]] && VERBOSE="Y" || VERBOSE="N"; fi; clrScreen && return
  elif [[ $1 = "homeInfo" ]]; then
    [[ ${key1} = "h" ]] && show_home_info="false" && line=0 && clrScreen && return
  elif [[ $1 = "peersInfo" ]]; then
    [[ ${key1} = "b" ]] && show_peers_info="false" && line=0 && clrScreen && return
  elif [[ $1 = "peers" ]]; then
    [[ ${key1} = "h" ]] && show_peers="false" && clrScreen && return
    [[ ${key1} = "i" ]] && show_peers_info="true" && clrScreen && return
    if [[ ${key2} = "[C" && ${show_peers} = "true" ]]; then # Right arrow
      [[ ${peerCNT} -gt ${peerNbr} ]] && peerNbr_start=$((peerNbr_start+PEER_LIST_CNT)) && clrScreen && return
    fi
    if [[ ${key2} = "[D" && ${show_peers} = "true" ]]; then # Left arrow
      [[ ${peerNbr_start} -gt ${PEER_LIST_CNT} ]] && peerNbr_start=$((peerNbr_start-PEER_LIST_CNT)) && clrScreen && return
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
# Description: clear the screen, move to (0,0), and reset screen update counter
clrScreen () {
  clear
  screen_upd_cnt=0
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

# Description: Get index of first entry in array matching input string (no spaces allowed in search)
# $1 = string to match against, $2 = array to search
# returns index in array or -1 if not found
getArrayIndex () {
  local match=$1
  shift
  arr=("$@")
  for i in "${!arr[@]}"; do [[ ${arr[$i]} = *"${match}"* ]] && echo $i && return; done
  echo -1
}

logln() {
  [[ -z ${GLV_LOG} ]] && return
  local log_level=$1
  shift
  [[ -z $1 ]] && return
  echo -e "$@" | while read -r log_line; do
    log_line=$(sed -E 's/\x1b(\[[0-9;]*[a-zA-Z]|[0-9])//g' <<< ${log_line##*( )})
    [[ -z ${log_line} ]] && continue
    printf '%s %-8s %s\n' "$(date "+%F %T %Z")" "[${log_level}]" "${log_line}" >> "${GLV_LOG}"
  done
}

getPoolInfo () {
  # runs in background to not stall rest of gLiveView while fetching data
  if ! pool_info=$(curl -sSL -f -X POST -H "Content-Type: application/json" -d '{"_pool_bech32_ids":["'${pool_id_bech32}'"]}' "${KOIOS_API}/pool_info" 2>&1); then
    [[ -n ${GLV_LOG} ]] && logln "ERROR" "${pool_info}"
    return
  fi
  [[ ${pool_info} = '[]' ]] && return
  echo ${pool_info} > ${pool_info_file}
}

parsePoolInfo () {
  pool_info_tsv=$(jq -r '[
  .[0].active_epoch_no //0,
  .[0].vrf_key_hash //"-",
  .[0].margin //0,
  .[0].fixed_cost //0,
  .[0].pledge //0,
  .[0].reward_addr //"-",
  (.[0].owners|@json),
  (.[0].relays|@json),
  .[0].meta_url //"-",
  .[0].meta_hash //"-",
  (.[0].meta_json|@base64),
  .[0].pool_status //"-",
  .[0].retiring_epoch //"-",
  .[0].op_cert //"-",
  .[0].op_cert_counter //"null",
  .[0].active_stake //0,
  .[0].block_count //0,
  .[0].live_pledge //0,
  .[0].live_stake //0,
  .[0].live_delegators //0,
  .[0].live_saturation //0
  ] | @tsv' "${pool_info_file}")

  read -ra pool_info_arr <<< ${pool_info_tsv}

  p_active_epoch_no=${pool_info_arr[0]}
  p_vrf_key_hash=${pool_info_arr[1]}
  p_margin=${pool_info_arr[2]}
  p_fixed_cost=${pool_info_arr[3]}
  p_pledge=${pool_info_arr[4]}
  p_reward_addr=${pool_info_arr[5]}
  p_owners=${pool_info_arr[6]}
  p_relays=${pool_info_arr[7]}
  p_meta_url=${pool_info_arr[8]}
  p_meta_hash=${pool_info_arr[9]}
  p_meta_json=$(base64 -d <<< ${pool_info_arr[10]})
  p_pool_status=${pool_info_arr[11]}
  p_retiring_epoch=${pool_info_arr[12]}
  p_op_cert=${pool_info_arr[13]}
  p_op_cert_counter=${pool_info_arr[14]}
  p_active_stake=${pool_info_arr[15]}
  p_block_count=${pool_info_arr[16]}
  p_live_pledge=${pool_info_arr[17]}
  p_live_stake=${pool_info_arr[18]}
  p_live_delegators=${pool_info_arr[19]}
  p_live_saturation=${pool_info_arr[20]}

  rm ${pool_info_file}
}

getOpCert () {
  op_cert_disk="?"
  op_cert_chain="?"
  opcert_file="${POOL_DIR}/${POOL_OPCERT_FILENAME}"
  if [[ ! -f ${opcert_file} && -n ${CNODE_PID} ]]; then
    if [[ $(ps -p ${CNODE_PID} -o cmd=) =~ --shelley-operational-certificate[[:space:]]([^[:space:]]+) ]]; then
      opcert_file="${BASH_REMATCH[1]}"
    fi
  fi
  if [[ -f ${opcert_file} ]]; then
    op_cert="$(${CCLI} ${NETWORK_ERA} query kes-period-info ${NETWORK_IDENTIFIER} --op-cert-file "${opcert_file}")"
    [[ ${op_cert} =~ qKesNodeStateOperationalCertificateNumber.:[[:space:]]([0-9]+) ]] && op_cert_chain="${BASH_REMATCH[1]}"
    [[ ${op_cert} =~ qKesOnDiskOperationalCertificateNumber.:[[:space:]]([0-9]+) ]] && op_cert_disk="${BASH_REMATCH[1]}"
  fi
}

# Command    : checkPeers
# Description: Check peer connections
#              Inspired by ping script from Martin @ ATADA pool
checkPeers() {
  # initialize variables
  peerCNT=0; peerCNT0=0; peerCNT1=0; peerCNT2=0; peerCNT3=0; peerCNT4=0
  peerPCT1=0; peerPCT2=0; peerPCT3=0; peerPCT4=0
  peerPCT1items=0; peerPCT2items=0; peerPCT3items=0; peerPCT4items=0
  peerRTTSUM=0; peerRTTAVG=0
  peersFiltered=(); rttResults=(); rttResultsSorted=""
  geoIPquery="[]"; geoIPqueryCNT=0

  command -v dig >/dev/null && ext_ip_resolve=$(dig @resolver1.opendns.com ANY myip.opendns.com +short) || ext_ip_resolve=""

  if [[ ${use_lsof} = 'Y' ]]; then
    peers_in=$(lsof -Pnl +M | grep ESTABLISHED | awk -v pid="${CNODE_PID}" -v port=":${CNODE_PORT}->" '$2 == pid && $9 ~ port {print $9}' | awk -F "->" '{print $2}')
    peers_out=$(lsof -Pnl +M | grep ESTABLISHED | awk -v pid="${CNODE_PID}" -v port=":(${CNODE_PORT}|${EKG_PORT}|${PROM_PORT})->" '$2 == pid && $9 !~ port {print $9}' | awk -F "->" '{print $2}')
  else
    peers_in=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | awk -v port=":${CNODE_PORT}" '$3 ~ port {print $4}')
    peers_out=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | awk -v port=":(${CNODE_PORT}|${EKG_PORT}|${PROM_PORT})" '$3 !~ port {print $4}')
  fi

  [[ -z ${peers_in} && -z ${peers_out} ]] && return

  for peer in ${peers_in}; do

    if [[ ${peer} = "["* ]]; then # IPv6
      IFS=']' read -ra ipv6_peer <<< "${peer:1}"; unset IFS
      peerIP=${ipv6_peer[0]}
      peerPORT=${ipv6_peer[1]:1}
    else # IPv4
      peerIP=$(cut -d: -f1 <<< "${peer}")
      peerPORT=$(cut -d: -f2 <<< "${peer}")
    fi

    if [[ -z ${peerIP} || -z ${peerPORT} || (${HIDE_DUPLICATE_IPS} = 'Y' && ${peerIP} = 127.0.0.1) || (${HIDE_DUPLICATE_IPS} = 'Y' && ${peerIP} = "${ext_ip_resolve}" && ${peerPORT} = "${CNODE_PORT}") ]]; then
      continue
    fi

    [[ ${HIDE_DUPLICATE_IPS} = 'Y' && $(getArrayIndex "${peerIP};" "${peersFiltered[@]}") -ge 0 ]] && continue # IP already added and duplicates not wanted

    peersFiltered+=("${peerIP};${peerPORT};i")

  done

  for peer in ${peers_out}; do

    if [[ ${peer} = "["* ]]; then # IPv6
      IFS=']' read -ra ipv6_peer <<< "${peer:1}"; unset IFS
      peerIP=${ipv6_peer[0]}
      peerPORT=${ipv6_peer[1]:1}
    else # IPv4
      peerIP=$(cut -d: -f1 <<< "${peer}")
      peerPORT=$(cut -d: -f2 <<< "${peer}")
    fi

    if [[ -z ${peerIP} || -z ${peerPORT} || (${HIDE_DUPLICATE_IPS} = 'Y' && ${peerIP} = 127.0.0.1) || (${HIDE_DUPLICATE_IPS} = 'Y' && ${peerIP} = "${ext_ip_resolve}" && ${peerPORT} = "${CNODE_PORT}") ]]; then
      continue
    fi

    if [[ ${HIDE_DUPLICATE_IPS} = 'Y' ]]; then
      local peerIndex;peerIndex=$(getArrayIndex "${peerIP};" "${peersFiltered[@]}")
      if [[ ${peerIndex} -ge 0 ]]; then
        if [[ ${peersFiltered[$peerIndex]} != *o ]]; then
          peersFiltered[$peerIndex]="${peerIP};${peerPORT};i+o"
        fi
      else
        peersFiltered+=("${peerIP};${peerPORT};o")
      fi
    else
      peersFiltered+=("${peerIP};${peerPORT};o")
    fi

  done

  readarray -td '' peersFiltered < <(printf '%s\0' "${peersFiltered[@]}" | sort -z)

  peerCNT=${#peersFiltered[@]}

  print_start=$(( width - (${#peerCNT}*2) - 2 ))
  mvPos ${line} ${print_start}
  printf "${style_values_1}%${#peerCNT}s${NC}/${style_values_2}%s${NC}" "0" "${peerCNT}"

  # Ping every node in the list
  index=0
  lastpeerIP=""

  for peerIndex in "${!peersFiltered[@]}"; do

    IFS=";" read -r -a peer_arr <<< "${peersFiltered[$peerIndex]}"; unset IFS

    peerIP=${peer_arr[0]}
    peerPORT=${peer_arr[1]}
    peerDIR=${peer_arr[2]}

    if [[ ${ENABLE_IP_GEOLOCATION} = "Y" && "${peerIP}" != "${lastpeerIP}" ]] && ! isPrivateIP "${peerIP}"; then
      if [[ ! -v "geoIP[${peerIP}]" && $((++geoIPqueryCNT)) -le 100 ]]; then # not previously checked and less than 100 queries
        geoIPquery=$(jq --arg addr "${peerIP}" '. += [{"query": $addr, "fields": "city,countryCode,query"}]' <<< ${geoIPquery})
      fi
    fi

    if [[ "${peerIP}" = "${lastpeerIP}" && ${peerRTT} -ne 99999 ]]; then
      peerRTTSUM=$((peerRTTSUM + peerRTT)) # skip RTT check and reuse old ${peerRTT} number
    else
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
    fi
    lastpeerIP=${peerIP}

    # Update counters
      if [[ ${peerRTT} -lt 50    ]]; then ((peerCNT1++))
    elif [[ ${peerRTT} -lt 100   ]]; then ((peerCNT2++))
    elif [[ ${peerRTT} -lt 200   ]]; then ((peerCNT3++))
    elif [[ ${peerRTT} -lt 99999 ]]; then ((peerCNT4++))
    else ((peerCNT0++)); fi
    rttResults+=( "${peerRTT};${peerIP};${peerPORT};${peerDIR}" )

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

checkNodeVersion() {
  [[ ${running_node_version} = '?' ]] && return # ignore check if unable to fetch version from running node

  version=$("${CNODEBIN}" version)
  node_version=$(grep "cardano-node" <<< "${version}" | cut -d ' ' -f2)
  node_rev=$(grep "git rev" <<< "${version}" | cut -d ' ' -f3 | cut -c1-8)

  if [[ ${node_version} != "${running_node_version}" || ${node_rev} != "${running_node_rev}" ]]; then
    clrScreen
    printf "\n ${style_status_3}Node version mismatch${NC} - running version doesn't match found binary!"
    printf "\n\n Forgot to restart node after upgrade?"
    printf "\n\n Deployed version : ${node_version} (${node_rev}) => ${CNODEBIN}"
    printf "\n Running version  : ${running_node_version} (${running_node_rev})\n"
    waitToProceed && clrScreen
  fi
}

#####################################
# Static variables/calculations     #
#####################################
check_peers="false"
show_peers="false"
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
checkNodeVersion

fail_count=0
epoch_items_last=0
screen_upd_cnt=0

test_koios # KOIOS_API variable unset if check fails. Only tested once on startup.
pool_info_file=/dev/shm/pool_info
[[ -n ${KOIOS_API} ]] && getPoolID

getOpCert

tput civis # Disable cursor
stty -echo # Disable user input

clrScreen
tlines=$(tput lines) # set initial terminal lines
tcols=$(tput cols)   # set initial terminal columns
printf "${NC}"       # reset and set default color

unset cpu_now cpu_last

####################################
# Mithril Signer Section Variables #
####################################

mithrilSignerVars() {
  # mithril.env sourcing needed to have values in ${METRICS_SERVER_IP} and ${METRICS_SERVER_PORT}
  . ${MITHRIL_HOME}/mithril.env
  signerMetricsEnabled=$(grep -q "ENABLE_METRICS_SERVER=true" ${MITHRIL_HOME}/mithril.env && echo "true" || echo "false")
  if [[ "${signerMetricsEnabled}" == "true" ]] ; then
    mithrilSignerMetrics=$(curl -s "http://${METRICS_SERVER_IP}:${METRICS_SERVER_PORT}/metrics" 2>/dev/null | grep -v -E "HELP|TYPE" | sed 's/mithril_signer_//g')
    SIGNER_METRICS_HTTP_RESPONSE=$(curl --write-out "%{http_code}" --silent --output /dev/null --connect-timeout 2 http://${METRICS_SERVER_IP}:${METRICS_SERVER_PORT}/metrics)
    if [[ "$SIGNER_METRICS_HTTP_RESPONSE" -eq 200 ]] ; then
      signerServiceStatus='online'
    else
      signerServiceStatus='offline'
    fi
    unset SIGNER_METRICS_HTTP_RESPONSE
  fi
}


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
  while [[ ${line} -gt ${tlines} ]]; do
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

  [[ "${oldLine}" != "${line}" ]] && oldLine=$line && clrScreen # redraw everything, total height changed

  line=1; mvPos 1 1 # reset position

  # Gather some data
  getNodeMetrics
  [[ ${RETRIES} -gt 0 && ${fail_count} -eq ${RETRIES} ]] && printf -v error_msg "${style_status_3}COULD NOT CONNECT TO A RUNNING INSTANCE, ${RETRIES} FAILED ATTEMPTS IN A ROW!${NC}" && logln "ERROR" "${error_msg}" && myExit 1 "${error_msg}"
  CNODE_PID=$(pgrep -fn "$(basename ${CNODEBIN}).*.port ${CNODE_PORT}")
  if [[ -z ${CNODE_PID} ]]; then
    ((fail_count++))
    clrScreen && mvPos 2 2
    printf -v error_msg "${style_status_3}Connection to node lost, retrying (${fail_count}$([[ ${RETRIES} -gt 0 ]] && echo "/${RETRIES}"))!${NC}"
    printf ${error_msg}
    logln "ERROR" "${error_msg}"
    waitForInput && continue
  elif [[ ${fail_count} -ne 0 ]]; then # was failed but now ok, re-check
    checkNodeVersion
    fail_count=0
    getOpCert
  fi

  if [[ ${show_peers} = "false" ]]; then

    if [[ ${P2P_ENABLED} != true ]]; then
      if [[ ${use_lsof} = 'Y' ]]; then
        peers_in=$(lsof -Pnl +M | grep ESTABLISHED | awk -v pid="${CNODE_PID}" -v port=":${CNODE_PORT}->" '$2 == pid && $9 ~ port {print $9}' | awk -F "->" '{print $2}' | wc -l)
        peers_out=$(lsof -Pnl +M | grep ESTABLISHED | awk -v pid="${CNODE_PID}" -v port=":(${CNODE_PORT}|${EKG_PORT}|${PROM_PORT})->" '$2 == pid && $9 !~ port {print $9}' | awk -F "->" '{print $2}' | wc -l)
      else
        peers_in=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | awk -v port=":${CNODE_PORT}" '$3 ~ port {print}' | wc -l)
        peers_out=$(ss -tnp state established 2>/dev/null | grep "${CNODE_PID}," | awk -v port=":(${CNODE_PORT}|${EKG_PORT}|${PROM_PORT})" '$3 !~ port {print}' | wc -l)
      fi
    fi

    mem_rss="$(ps -q ${CNODE_PID} -o rss=)"
    read -ra cpu_now <<< "$(LC_NUMERIC=C awk '/cpu /{printf "%.f %.f", $2+$4,$2+$4+$5}' /proc/stat)"
    if [[ ${#cpu_now[@]} -eq 2 ]]; then
      if [[ ${#cpu_last[@]} -eq 2 ]]; then
        cpu_util=$(bc -l <<< "100*((${cpu_now[0]}-${cpu_last[0]})/(${cpu_now[1]}-${cpu_last[1]}))")
        if [[ ${cpu_util%.*} -gt 99 ]]; then
          cpu_util=$(LC_NUMERIC=C printf "%.0f" "${cpu_util}")
        elif [[ ${cpu_util%.*} -gt 9 ]]; then
          cpu_util=$(LC_NUMERIC=C printf "%.1f" "${cpu_util}")
        else
          cpu_util=$(LC_NUMERIC=C printf "%.2f" "${cpu_util}")
        fi
      else
        cpu_util="0.0"
      fi
      cpu_last=("${cpu_now[@]}")
    else
      cpu_util="0.0"
    fi
    if [[ ${forging_enabled} -eq 1 ]]; then
      [[ ${nodemode} != "Core" ]] && nodemode="Core" && getOpCert && clrScreen
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
      unset pool_info_last_upd
    fi
    if [[ ${nodemode} = "Core" ]]; then
      if [[ -n ${KOIOS_API} && -n ${pool_id_bech32} ]]; then
        if [[ -n ${pool_info_last_upd} && $(($(date -u +%s) - pool_info_last_upd)) -lt 3600 ]]; then
          : # nothing to do, pool info already fetched, processed and under 1h old
        elif [[ -f ${pool_info_file} ]]; then
          parsePoolInfo
          pool_info_last_upd=$(date -u +%s)
          clrScreen
        else
          getPoolInfo & # background process to not stall UI
        fi
      fi
    fi
  fi

  header_length=$(( ${#NODE_NAME} + ${#nodemode} + ${#running_node_version} + ${#running_node_rev} + ${#NETWORK_NAME} + 19 ))
  [[ ${header_length} -gt ${width} ]] && header_padding=0 || header_padding=$(( (width - header_length) / 2 ))
  printf "%${header_padding}s > ${style_values_2}%s${NC} - ${style_info}(%s - %s)${NC} : ${style_values_1}%s${NC} [${style_values_1}%s${NC}] < \n" "" "${NODE_NAME}" "${nodemode}" "${NETWORK_NAME}" "${running_node_version}" "${running_node_rev}" && ((line++))

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
    printf "${VL} ${style_info}%-$((width-3))s${NC} ${VL}\n" "Peer analysis started... please wait!"
    echo "${bdivider}"
    checkPeers
    peerNbr_start=1
    mvPos ${line} 1
    printf "${VL} ${style_info}%-46s${NC}" "Peer analysis done!" && closeRow
    printf -v peer_analysis_date '%(%Y-%m-%d %H:%M:%S)T' -1
    sleep 1
    [[ ${#geoIP[@]} -gt 0 ]] && declare -p geoIP > "$0.geodb"
  elif [[ ${show_peers} = "true" && ${show_peers_info} = "true" ]]; then
    printf "${VL}${STANDOUT} INFO ${NC} One-shot peer analysis last run at ${style_values_1}%s" "${peer_analysis_date}" && closeRow
    printf "${blank_line}\n" && ((line++))
    printf "${VL} Runs a latency test on connections to the node." && closeRow
    printf "${VL} Once the analysis is finished, RTTs(Round Trip Time) for each peer" && closeRow
    printf "${VL} is display and grouped in ranges of 0-50, 50-100, 100-200, 200<." && closeRow
    printf "${blank_line}\n" && ((line++))
    printf "${VL} Connections ping type order(unless overridden in settings):" && closeRow
    printf "${VL} 1. ${style_values_2}cncli${NC} - If available, this gives the most accurate measure as" && closeRow
    printf "${VL}    it checks the entire handshake process against the remote peer." && closeRow
    printf "${VL} 2. ${style_values_2}ss${NC} - Sends a TCP SYN package to ping the remote peer on" && closeRow
    printf "${VL}    the cardano-node port. Should give ~100%% success rate." && closeRow
    printf "${VL} 3. ${style_values_2}tcptraceroute${NC} - Same as ss" && closeRow
    printf "${VL} 4. ${style_values_2}ping${NC} - fallback method using ICMP ping against IP." && closeRow
    printf "${VL}    Only work if the FW of remote peer accepts ICMP traffic." && closeRow
  elif [[ ${show_peers} = "true" ]]; then
    printf "${VL}       RTT : Peers / Percent" && closeRow

    printf "${VL}    0-50ms : ${style_values_1}%5s${NC}   ${style_values_1}%.f${NC}%% ${style_status_1}" "${peerCNT1}" "${peerPCT1}"
    mvPos ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT1items} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    closeRow

    printf "${VL}  50-100ms : ${style_values_1}%5s${NC}   ${style_values_1}%.f${NC}%% ${style_status_2}" "${peerCNT2}" "${peerPCT2}"
    mvPos ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT2items} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    closeRow

    printf "${VL} 100-200ms : ${style_values_1}%5s${NC}   ${style_values_1}%.f${NC}%% ${style_status_3}" "${peerCNT3}" "${peerPCT3}"
    mvPos ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT3items} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    closeRow

    printf "${VL}   200ms < : ${style_values_1}%5s${NC}   ${style_values_1}%.f${NC}%% ${style_status_4}" "${peerCNT4}" "${peerPCT4}"
    mvPos ${line} ${bar_col_small}
    for i in $(seq 0 $((granularity_small-1))); do
      [[ $i -lt ${peerPCT4items} ]] && printf "${char_marked}" || printf "${NC}${char_unmarked}"
    done
    closeRow

    echo "${m3divider}" && ((line++))

    printf "${VL} Total / Undetermined : ${style_values_1}%s${NC} / " "${peerCNT}"
    [[ ${peerCNT0} -eq 0 ]] && printf "${style_values_1}0${NC}" || printf "${style_values_4}%s${NC}" "${peerCNT0}"
    mvPos ${line} $((two_col_second + 1))
    if [[ ${peerRTTAVG} -ge 200 ]]; then printf "Average RTT : ${style_status_4}%s${NC} ms" "${peerRTTAVG}"
    elif [[ ${peerRTTAVG} -ge 100 ]]; then printf "Average RTT : ${style_status_3}%s${NC} ms" "${peerRTTAVG}"
    elif [[ ${peerRTTAVG} -ge 50  ]]; then printf "Average RTT : ${style_status_2}%s${NC} ms" "${peerRTTAVG}"
    elif [[ ${peerRTTAVG} -ge 0   ]]; then printf "Average RTT : ${style_status_1}%s${NC} ms" "${peerRTTAVG}"
    else printf "Average RTT : ${style_status_3}---${NC} ms"; fi
    closeRow

    if [[ -n ${rttResultsSorted} ]]; then
      echo "${m3divider}" && ((line++))

      printf "${VL}${style_info}   # %24s  RTT   Geolocation${NC}\n" "REMOTE PEER"
      header_line=$((line++))

      peerNbr=0
      peerLocationWidth=$((width-41))
      for peer in ${rttResultsSorted}; do
        ((peerNbr++))
        [[ ${peerNbr} -lt ${peerNbr_start} ]] && continue
        IFS=";" read -a peerData <<< ${peer}; unset IFS
        peerRTT="${peerData[0]}"
        peerPORT="${peerData[2]}"
        peerDIR="${peerData[3]}"
        if [[ ${peerData[1]} = *:* ]]; then # IPv6
          IFS=":" read -a ipv6IP <<< ${peerData[1]}
          if [[ ${#ipv6IP[@]} -le 3 ]]; then
            peerIP="[${peerData[1]}]"
          else
            peerIP="[${ipv6IP[0]}...${ipv6IP[-2]}:${ipv6IP[-1]}]"
          fi
        else
          peerIP="${peerData[1]}"
        fi
        IFS=',' read -ra peerLocation <<< "${geoIP[${peerIP}]}"; unset IFS
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
          if [[ ${peerRTT} -lt 50    ]]; then printf "${VL} %3s %19s:%-5s ${style_status_1}%-5s${NC} ${style_values_4}%s" "${peerNbr}" "${peerIP}" "${peerPORT}" "${peerRTT}" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"
        elif [[ ${peerRTT} -lt 100   ]]; then printf "${VL} %3s %19s:%-5s ${style_status_2}%-5s${NC} ${style_values_4}%s" "${peerNbr}" "${peerIP}" "${peerPORT}" "${peerRTT}" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"
        elif [[ ${peerRTT} -lt 200   ]]; then printf "${VL} %3s %19s:%-5s ${style_status_3}%-5s${NC} ${style_values_4}%s" "${peerNbr}" "${peerIP}" "${peerPORT}" "${peerRTT}" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"
        elif [[ ${peerRTT} -lt 99999 ]]; then printf "${VL} %3s %19s:%-5s ${style_status_4}%-5s${NC} ${style_values_4}%s" "${peerNbr}" "${peerIP}" "${peerPORT}" "${peerRTT}" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"
        else printf "${VL} %3s %19s:%-5s %-5s ${style_values_4}%s" "${peerNbr}" "${peerIP}" "${peerPORT}" "---" "$(alignLeft ${peerLocationWidth} "${peerLocationFmt}")"; fi
        closeRow
        [[ ${peerNbr} -eq $((peerNbr_start+PEER_LIST_CNT-1)) ]] && break
      done

      [[ ${peerNbr_start} -gt 1 ]] && nav_str="< " || nav_str=""
      nav_str+="[${peerNbr_start}-${peerNbr}]"
      [[ ${peerCNT} -gt ${peerNbr} ]] && nav_str+=" >"
      mvPos ${header_line} $((width-${#nav_str}-2))
      printf "${style_values_3} %s ${NC} ${VL}\n" "${nav_str}" || printf "  %s ${VL}\n" "${nav_str}"
      mvPos ${line} 1
    fi
  elif [[ ${show_home_info} = "true" ]]; then
    printf "${VL}${STANDOUT} INFO ${NC} Displays live metrics gathered from node EKG endpoint" && closeRow
    printf "${blank_line}\n" && ((line++))
    printf "${VL} ${style_values_2}Upper Main Section${NC}" && closeRow
    printf "${VL} Epoch number & progress is live from node while calculation of date" && closeRow
    printf "${VL} until epoch boundary is based on genesis parameters. Reference tip" && closeRow
    printf "${VL} and difference show how far behind the last block is from real time." && closeRow
    printf "${VL} Forks is how many times the blockchain branched off in a different" && closeRow
    printf "${VL} direction since node start (and discarded blocks by doing so)." && closeRow
    printf "${VL} P2P Connections shows how many peers the node pushes to/pulls from." && closeRow
    printf "${VL} Block propagation metrics are discussed in the documentation." && closeRow
    printf "${VL} RSS/Live/Heap shows the memory utilization of RSS/live/heap data." && closeRow
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
    epoch_progress_1dec=$(LC_NUMERIC=C printf "%2.1f" "${epoch_progress}")
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
    printf "Forks      : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${forks}"
    closeRow

    # row 2
    printf "${VL} Slot       : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${slotnum}"
    mvThreeSecond
    if [[ ${slotnum} -eq 0 ]]; then
      printf "Status     : ${style_info}%-${three_col_2_value_width}s${NC}" "starting"
    elif [[ ${SHELLEY_TRANS_EPOCH} -eq -1 ]]; then
      printf "Status     : ${style_info}%-${three_col_2_value_width}s${NC}" "syncing"
    elif [[ ${tip_diff} -le $(slotInterval) ]]; then
      printf "Tip (diff) : ${style_status_1}%-${three_col_2_value_width}s${NC}" "${tip_diff} :)"
    elif [[ ${tip_diff} -le 600 ]]; then
      printf "Tip (diff) : ${style_status_2}%-${three_col_2_value_width}s${NC}" "${tip_diff} :|"
    else
      sync_progress=$(echo "(${slotnum}/${tip_ref})*100" | bc -l)
      printf "Syncing    : ${style_info}%-${three_col_2_value_width}s${NC}" "$(LC_NUMERIC=C printf "%2.1f" "${sync_progress}")%"
    fi
    mvThreeThird
    printf "Total Tx   : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${tx_processed}"
    closeRow

    # row 3
    printf "${VL} Slot epoch : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${slot_in_epoch}"
    mvThreeSecond
    printf "Density    : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${density}"
    mvThreeThird
    mempool_tx_bytes=$((mempool_bytes/1024))
    printf "Pending Tx : ${style_values_1}%s${NC}/${style_values_1}%s${NC}%-$((three_col_1_value_width - ${#mempool_tx} - ${#mempool_tx_bytes} - 3))s" "${mempool_tx}" "${mempool_tx_bytes}" "K"
    closeRow

    echo "${conndivider}" && ((line++))

    if [[ ${P2P_ENABLED} = true ]]; then

      # row 1
      printf "${VL} P2P        : ${style_status_1}%-${three_col_2_value_width}s${NC}" "enabled"
      mvThreeSecond
      printf "Cold Peers : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${peers_cold}"
      mvThreeThird
      printf "Uni-Dir    : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${conn_uni_dir}"
      closeRow

      # row 2
      printf "${VL} Incoming   : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${conn_incoming}"
      mvThreeSecond
      printf "Warm Peers : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${peers_warm}"
      mvThreeThird
      printf "Bi-Dir     : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${conn_bi_dir}"
      closeRow

      # row 3
      printf "${VL} Outgoing   : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${conn_outgoing}"
      mvThreeSecond
      printf "Hot Peers  : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${peers_hot}"
      mvThreeThird
      printf "Duplex     : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${conn_duplex}"
      closeRow

    else

      # row 1
      printf "${VL} P2P        : ${style_status_2}%-${three_col_2_value_width}s${NC}" "disabled"
      mvThreeSecond
      printf "Incoming   : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${peers_in}"
      mvThreeThird
      printf "Outgoing   : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${peers_out}"
      closeRow

    fi

    echo "${propdivider}" && ((line++))

    LC_NUMERIC=C printf -v block_delay_rounded "%.2f" ${block_delay}
    [[ ${blocks_w1s} = 1.* ]] && blocks_w1s_pct=100 || LC_NUMERIC=C printf -v blocks_w1s_pct "%.2f" "$(bc -l <<<"(${blocks_w1s}*100)")"
    [[ ${blocks_w3s} = 1.* ]] && blocks_w3s_pct=100 || LC_NUMERIC=C printf -v blocks_w3s_pct "%.2f" "$(bc -l <<<"(${blocks_w3s}*100)")"
    [[ ${blocks_w5s} = 1.* ]] && blocks_w5s_pct=100 || LC_NUMERIC=C printf -v blocks_w5s_pct "%.2f" "$(bc -l <<<"(${blocks_w5s}*100)")"

    if [[ ${VERBOSE} = "Y" ]]; then

      # row 1
      printf "${VL} Last Block : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#block_delay_rounded}))s" "${block_delay_rounded}" "s"
      mvThreeSecond
      printf "Served     : ${style_values_1}%s${NC}" "${blocks_served}"
      mvThreeThird
      printf "Late (>5s) : ${style_values_1}%s${NC}" "${blocks_late}"
      closeRow

      # row 2
      printf "${VL} Within 1s  : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#blocks_w1s_pct}))s" "${blocks_w1s_pct}" "%"
      mvThreeSecond
      printf "Within 3s  : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#blocks_w3s_pct}))s" "${blocks_w3s_pct}" "%"
      mvThreeThird
      printf "Within 5s  : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#blocks_w5s_pct}))s" "${blocks_w5s_pct}" "%"
      closeRow

    else

      # row 1
      printf "${VL} Last Block : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#block_delay_rounded}))s" "${block_delay_rounded}" "s"
      mvThreeSecond
      blocks_w5s_value_width=$(( (three_col_width*2) - 23 - 6 - ${#blocks_w1s_pct} - ${#blocks_w3s_pct} ))
      printf "Less than 1|3|5s [%%] : ${style_values_1}%s${NC} | ${style_values_1}%s${NC} | ${style_values_1}%-${blocks_w5s_value_width}s${NC}" "${blocks_w1s_pct}" "${blocks_w3s_pct}" "${blocks_w5s_pct}"
      closeRow

    fi

    echo "${resourcesdivider}" && ((line++))

    LC_NUMERIC=C printf -v mem_rss_gb "%.1f" "$(bc -l <<<"(${mem_rss}/1048576)")"
    [[ $(df -h ${CNODE_HOME}) =~ ([0-9.]+)% ]] && disk_usage=${BASH_REMATCH[1]} || disk_usage="?"

    if [[ ${VERBOSE} = "Y" ]]; then

      LC_NUMERIC=C printf -v mem_live_gb "%.1f" "$(bc -l <<<"(${mem_live}/1073741824)")"
      LC_NUMERIC=C printf -v mem_heap_gb "%.1f" "$(bc -l <<<"(${mem_heap}/1073741824)")"

      # row 1
      printf "${VL} CPU (sys)  : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#cpu_util}))s" "${cpu_util}" "%"
      mvThreeSecond
      printf "Mem (RSS)  : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#mem_rss_gb}))s" "${mem_rss_gb}" "G"
      mvThreeThird
      printf "GC Minor   : ${style_values_1}%s${NC}" "${gc_minor}"
      closeRow

      # row 2
      printf "${VL} Disk util  : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#disk_usage}))s" "${disk_usage}" "%"
      mvThreeSecond
      printf "Mem (Live) : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#mem_live_gb}))s" "${mem_live_gb}" "G"
      mvThreeThird
      printf "GC Major   : ${style_values_1}%s${NC}" "${gc_major}"
      closeRow

      # row 3
      printf "${VL}"
      mvThreeSecond
      printf "Mem (Heap) : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#mem_heap_gb}))s" "${mem_heap_gb}" "G"
      closeRow

    else

      # row 1
      printf "${VL} CPU (sys)  : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#cpu_util}))s" "${cpu_util}" "%"
      mvThreeSecond
      printf "Mem (RSS)  : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#mem_rss_gb}))s" "${mem_rss_gb}" "G"
      mvThreeThird
      printf "Disk util  : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#disk_usage}))s" "${disk_usage}" "%"
      closeRow

    fi

    ## Core section ##
    if [[ ${nodemode} = "Core" ]]; then
      echo "${coredivider}" && ((line++))

      printf "${VL} KES current|remaining|exp"
      mvTwoSecond
      printf ": ${style_values_1}%s${NC} | " "${kesperiod}"
      if [[ ${remaining_kes_periods} -le 0 ]]; then
        printf "${style_status_4}%s${NC}" "${remaining_kes_periods}"
      elif [[ ${remaining_kes_periods} -le 8 ]]; then
        printf "${style_status_3}%s${NC}" "${remaining_kes_periods}"
      else
        printf "${style_values_1}%s${NC}" "${remaining_kes_periods}"
      fi
      [[ ${kes_expiration} =~ (.+[0-9]+:[0-9]+):[0-9]+(.*) ]] && kes_expiration_nosec="${BASH_REMATCH[1]}${BASH_REMATCH[2]}" || kes_expiration_nosec="?"
      printf " | ${style_values_1}%s${NC}" "${kes_expiration_nosec}"
      closeRow

      # OP Cert
      if isNumber ${op_cert_chain}; then
        op_cert_chain_fmt="${style_values_1}"
        if isNumber ${op_cert_disk} && [[ ${op_cert_disk} -ge ${op_cert_chain} && ${op_cert_disk} -le $((op_cert_chain+1)) ]]; then op_cert_disk_fmt="${style_values_1}"; else op_cert_disk_fmt="${style_status_3}"; fi
      else
        op_cert_chain_fmt="${style_values_3}"
        if isNumber ${op_cert_disk}; then op_cert_disk_fmt="${style_values_1}"; else op_cert_disk_fmt="${style_values_3}"; fi
      fi
      printf "${VL} OP Cert disk|chain"
      mvTwoSecond
      printf ": ${op_cert_disk_fmt}%s${NC} | ${op_cert_chain_fmt}%s${NC}" "${op_cert_disk}" "${op_cert_chain}"
      closeRow

      if [[ ${VERBOSE} = "Y" ]]; then
        printf "${VL} Missed slot leader checks"
        mvTwoSecond
        LC_NUMERIC=C printf -v missed_slots_pct "%.4f" "$(bc -l <<<"(${missed_slots}/(${about_to_lead}+${missed_slots}))*100")"
        printf ": ${style_values_1}%s${NC} (${style_values_1}%s${NC} %%)" "${missed_slots}" "${missed_slots_pct}"
        closeRow
      fi

      if [[ -n ${p_active_stake} ]]; then

        # row 1
        printf "${VL} Blocks     : ${style_values_1}%s${NC}" "${p_block_count}"
        mvThreeSecond
        compactNumber $((p_active_stake/1000000))
        printf "Act Stake  : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#cn_value}))s" "${cn_value}" "${cn_suffix}"
        mvThreeThird
        compactNumber $((p_pledge/1000000))
        printf "Pledge     : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#cn_value}))s" "${cn_value}" "${cn_suffix}"
        closeRow

        # row 2
        compactNumber $((p_fixed_cost/1000000))
        printf "${VL} Fixed Fee  : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#cn_value}))s" "${cn_value}" "${cn_suffix}"
        mvThreeSecond
        compactNumber $((p_live_stake/1000000))
        printf "Live Stake : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#cn_value}))s" "${cn_value}" "${cn_suffix}"
        mvThreeThird
        [[ ${p_live_pledge} -ge ${p_pledge} ]] && p_live_pledge_fmt="${style_values_1}" || p_live_pledge_fmt="${style_status_3}"
        compactNumber $((p_live_pledge/1000000))
        printf "Live Pledge: ${p_live_pledge_fmt}%s${NC}%-$((three_col_3_value_width - ${#cn_value}))s" "${cn_value}" "${cn_suffix}"
        closeRow

        # row 3
        margin_fee=$(fractionToPCT ${p_margin})
        ! validateDecimalNbr ${margin_fee} && margin_fee="?"
        printf "${VL} Margin Fee : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#margin_fee}))s" "${margin_fee}" "%"
        mvThreeSecond
        printf "Delegators : ${style_values_1}%-${three_col_3_value_width}s${NC}" "${p_live_delegators}"
        mvThreeThird
        printf "Saturation : ${style_values_1}%s${NC}%-$((three_col_3_value_width - ${#p_live_saturation}))s" "${p_live_saturation}" "%"
        closeRow
      fi

      printf "${blockdivider}\n" && ((line++))

      if [[ -f "${BLOCKLOG_DB}" ]]; then
        invalid_cnt=0; missed_cnt=0; ghosted_cnt=0; stolen_cnt=0; confirmed_cnt=0; adopted_cnt=0; leader_cnt=0
        for status_type in $(sqlite3 "${BLOCKLOG_DB}" "SELECT status, COUNT(status) FROM blocklog WHERE epoch=${epochnum} GROUP BY status;" 2>/dev/null); do
          IFS='|' read -ra status <<< ${status_type}; unset IFS
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
        lost_cnt=$(( invalid_cnt + missed_cnt + ghosted_cnt + stolen_cnt ))
        leader_cnt=$(( leader_cnt + adopted_cnt + lost_cnt ))
        leader_next=$(sqlite3 "${BLOCKLOG_DB}" "SELECT at FROM blocklog WHERE datetime(at) > datetime('now') ORDER BY slot ASC LIMIT 1;" 2>/dev/null)
        IFS='|' read -ra epoch_stats <<< "$(sqlite3 "${BLOCKLOG_DB}" "SELECT epoch_slots_ideal, max_performance FROM epochdata WHERE epoch=${epochnum};" 2>/dev/null)"; unset IFS
        if [[ ${#epoch_stats[@]} -eq 0 ]]; then epoch_stats=("-" "-"); else epoch_stats[1]="${epoch_stats[1]}%"; fi

        [[ ${confirmed_cnt} -ne ${adopted_cnt} ]] && confirmed_fmt="${style_status_2}" || confirmed_fmt="${style_values_2}"

        if [[ ${VERBOSE} = "Y" ]]; then

          [[ ${invalid_cnt} -eq 0 ]] && invalid_fmt="${style_values_1}" || invalid_fmt="${style_status_3}"
          [[ ${missed_cnt} -eq 0 ]] && missed_fmt="${style_values_1}" || missed_fmt="${style_status_3}"
          [[ ${ghosted_cnt} -eq 0 ]] && ghosted_fmt="${style_values_1}" || ghosted_fmt="${style_status_3}"
          [[ ${stolen_cnt} -eq 0 ]] && stolen_fmt="${style_values_1}" || stolen_fmt="${style_status_3}"

          # row 1
          printf "${VL} Leader     : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${leader_cnt}"
          mvThreeSecond
          printf "Adopted    : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${adopted_cnt}"
          mvThreeThird
          printf "Missed     : ${missed_fmt}%-${three_col_3_value_width}s${NC}" "${missed_cnt}"
          closeRow

          # row 2
          printf "${VL} Ideal      : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${epoch_stats[0]}"
          mvThreeSecond
          printf "Confirmed  : ${confirmed_fmt}%-${three_col_2_value_width}s${NC}" "${confirmed_cnt}"
          mvThreeThird
          printf "Ghosted    : ${ghosted_fmt}%-${three_col_3_value_width}s${NC}" "${ghosted_cnt}"
          closeRow

          # row 3
          printf "${VL} Luck       : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${epoch_stats[1]}"
          mvThreeSecond
          printf "Invalid    : ${invalid_fmt}%-${three_col_2_value_width}s${NC}" "${invalid_cnt}"
          mvThreeThird
          printf "Stolen     : ${stolen_fmt}%-${three_col_3_value_width}s${NC}" "${stolen_cnt}"
          closeRow

        else

          [[ ${lost_cnt} -eq 0 ]] && lost_fmt="${style_values_1}" || lost_fmt="${style_status_3}"

          # row 1
          printf "${VL} Leader     : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${leader_cnt}"
          mvThreeSecond
          printf "Luck       : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${epoch_stats[1]}"
          mvThreeThird
          printf "Confirmed  : ${confirmed_fmt}%-${three_col_2_value_width}s${NC}" "${confirmed_cnt}"
          closeRow

          # row 2
          printf "${VL} Ideal      : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${epoch_stats[0]}"
          mvThreeSecond
          printf "Adopted    : ${style_values_1}%-${three_col_2_value_width}s${NC}" "${adopted_cnt}"
          mvThreeThird
          printf "Lost       : ${lost_fmt}%-${three_col_2_value_width}s${NC}" "${lost_cnt}"
          closeRow

        fi

        if [[ -n ${leader_next} ]]; then
          leader_time_left=$((  $(date -u -d ${leader_next} +%s) - $(printf '%(%s)T\n' -1) ))
          if [[ ${leader_time_left} -gt 0 ]]; then
            setSizeAndStyleOfProgressBar ${leader_time_left}
            leader_time_left_fmt="$(timeLeft ${leader_time_left})"
            leader_progress=$(echo "(1-(${leader_time_left}/${leader_bar_span}))*100" | bc -l)
            leader_items=$(( ($(printf %.0f "${leader_progress}") * granularity_small) / 100 ))
            printf "${VL} Next block : ${style_values_1}%-$((two_col_width-14))s${NC}" "${leader_time_left_fmt}"
            mvPos ${line} ${bar_col_small}
            if [[ -z ${leader_bar} || ${leader_items} -ne ${leader_items_last} ]]; then
              leader_bar=""; leader_items_last=${leader_items}
              for i in $(seq 0 $((granularity_small-1))); do
                [[ $i -lt ${leader_items} ]] && leader_bar+=$(printf "${leader_bar_style}${char_marked}") || leader_bar+=$(printf "${NC}${char_unmarked}")
              done
            fi
            printf "${leader_bar}" && closeRow
          fi
        fi
      else
        [[ ${isleader} -ne ${adopted} ]] && adopted_fmt="${style_status_2}" || adopted_fmt="${style_values_2}"
        [[ ${didntadopt} -eq 0 ]] && invalid_fmt="${style_values_1}" || invalid_fmt="${style_status_3}"

        printf "${VL} Leader : ${style_values_1}%-${three_col_1_value_width}s${NC}" "${isleader}"
        mvThreeSecond
        printf "Adopted : ${adopted_fmt}%-${three_col_2_value_width}s${NC}" "${adopted}"
        mvThreeThird
        printf "Invalid : ${invalid_fmt}%-${three_col_3_value_width}s${NC}" "${didntadopt}"
        closeRow
      fi
    fi
    if [[ "${MITHRIL_SIGNER_ENABLED}" == "Y" ]]; then
      # Mithril Signer Section
      mithrilSignerVars
      printf "${mithrildivider}\n" && ((line++))
      get_metric_value() {
        local metric_name="$1"
        local metric_value
        while IFS= read -r line; do
            if [[ $line =~ ${metric_name}[[:space:]]+([0-9]+) ]]; then
                metric_value="${BASH_REMATCH[1]}"
                echo "$metric_value"
                return
            fi
        done <<< "$mithrilSignerMetrics"
      }
      metrics=(
          "runtime_cycle_total_since_startup"
          "signer_registration_success_last_epoch"
          "signer_registration_success_since_startup"
          "signer_registration_total_since_startup"
          "signature_registration_success_last_epoch"
          "signature_registration_success_since_startup"
          "signature_registration_total_since_startup"
      )
      cycle_total_VAL=$(get_metric_value "runtime_cycle_total_since_startup")
      signer_reg_epoch_VAL=$(get_metric_value "signer_registration_success_last_epoch")
      signer_reg_success_VAL=$(get_metric_value "signer_registration_success_since_startup")
      signer_reg_total_VAL=$(get_metric_value "signer_registration_total_since_startup")
      signatures_epoch_VAL=$(get_metric_value "signature_registration_success_last_epoch")
      signatures_reg_success_VAL=$(get_metric_value "signature_registration_success_since_startup")
      signatures_reg_total_VAL=$(get_metric_value "signature_registration_total_since_startup")
      if [[ ${VERBOSE} = "Y" ]]; then
        printf "${VL} Status     : ${style_values_2}%-${three_col_1_value_width}s${NC}" "$signerServiceStatus"
        printf "           : Registered Epoch     : ${style_values_1}%-${three_col_1_value_width}s${NC}" "$signer_reg_epoch_VAL"
        closeRow
        printf "${VL} Cycles     : ${style_values_1}%-${three_col_1_value_width}s${NC}" "$cycle_total_VAL"
        printf "           : Signing in Epoch     : ${style_values_2}%-${three_col_1_value_width}s${NC}" "$signatures_epoch_VAL"
        closeRow
        printf "${VL} Signatures : ${style_values_2}%-${three_col_1_value_width}s${NC}" "$signatures_reg_success_VAL"
        printf "           : Total Signatures     : ${style_values_1}%-${three_col_1_value_width}s${NC}" "$signatures_reg_total_VAL"
        closeRow
        printf "${VL} Registered : ${style_values_1}%-${three_col_1_value_width}s${NC}" "$signer_reg_success_VAL"
        printf "           : Registered Total     : ${style_values_1}%-${three_col_1_value_width}s${NC}" "$signer_reg_total_VAL"
        closeRow
      else
        printf "${VL} Status     : ${style_values_2}%-${three_col_1_value_width}s${NC}" "$signerServiceStatus"
        printf "           : Registered Epoch     : ${style_values_1}%-${three_col_1_value_width}s${NC}" "$signer_reg_epoch_VAL"
        closeRow
        printf "${VL} Cycles     : ${style_values_1}%-${three_col_1_value_width}s${NC}" "$cycle_total_VAL"
        printf "           : Signing in Epoch     : ${style_values_2}%-${three_col_1_value_width}s${NC}" "$signatures_epoch_VAL"
        closeRow
        printf "${VL} Signatures : ${style_values_2}%-${three_col_1_value_width}s${NC}" "$signatures_reg_success_VAL"
        printf "           : Total Signatures     : ${style_values_1}%-${three_col_1_value_width}s${NC}" "$signatures_reg_total_VAL"
        closeRow
      fi
    fi
  fi



  [[ ${check_peers} = "true" ]] && check_peers=false && show_peers=true && clrScreen && continue

  echo "${bdivider}" && ((line++))
  printf " TG Announcement/Support channel: ${style_info}t.me/CardanoKoios/9759${NC}\n\n" && line=$((line+2))

  [[ -z ${oldLine} ]] && oldLine=$line

  if [[ ${show_peers} = "true" && ${show_peers_info} = "true" ]]; then
    printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[b] Back to Peer Analysis${NC}"
    clrLine
    waitForInput "peersInfo"
  elif [[ ${show_peers} = "true" ]]; then
    printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[h] Home${NC} | ${style_info}[i] Info${NC} | Left/Right : Navigate List"
    clrLine
    waitForInput "peers"
  elif [[ ${show_home_info} = "true" ]]; then
    printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[h] Home${NC}"
    clrLine
    waitForInput "homeInfo"
  else
    [[ ${VERBOSE} = "Y" ]] && verbose_label="Compact" || verbose_label="Verbose"
    printf " ${style_info}[esc/q] Quit${NC} | ${style_info}[i] Info${NC} | ${style_info}[p] Peer Analysis${NC} | ${style_info}[v] ${verbose_label}${NC}"
    clrLine
    waitForInput
  fi

  [[ $((++screen_upd_cnt)) -gt ${REPAINT_RATE} ]] && clrScreen
done
