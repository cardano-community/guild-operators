#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2034
# shellcheck source=/dev/null

PARENT="$(dirname $0)"
[[ -f "${PARENT}"/env ]] && . "${PARENT}"/env offline

######################################
# User Variables - Change as desired #
######################################

CNODE_HOSTNAME="CHANGE ME"  # (Optional) Must resolve to the IP you are requesting from
CNODE_VALENCY=1             # (Optional) for multi-IP hostnames
MAX_PEERS=15                # Maximum number of peers to return on successful fetch (note that a single peer may include valency of up to 3)
#CUSTOM_PEERS="None"        # *Additional* custom peers to (IP,port[,valency]) to add to your target topology.json
                            # eg: "10.0.0.1,3001|10.0.0.2,3002|relays.mydomain.com,3003,3"
#BATCH_AUTO_UPDATE=N        # Set to Y to automatically update the script if a new version is available without user interaction

######################################
# Do NOT modify code below           #
######################################

PARENT="$(dirname $0)"
[[ -f "${PARENT}"/.env_branch ]] && BRANCH="$(cat ${PARENT}/.env_branch)" || BRANCH="master"

usage() {
  cat <<-EOF
		Usage: $(basename "$0") [-b <branch name>] [-f] [-p]
		Topology Updater - Build topology with community pools

		-f    Disable fetch of a fresh topology file
		-p    Disable node alive push to Topology Updater API
		-u    Skip script update check overriding UPDATE_CHECK value in env
		-b    Use alternate branch to check for updates - only for testing/development (Default: master)
		
		EOF
  exit 1
}

TU_FETCH=Y
TU_PUSH=Y
SKIP_UPDATE=N

while getopts :fpub: opt; do
  case ${opt} in
    f ) TU_FETCH=N ;;
    p ) TU_PUSH=N ;;
    u ) SKIP_UPDATE=Y ;;
    b ) echo "${OPTARG}" > "${PARENT}"/.env_branch ;;
    \? ) usage ;;
  esac
done
shift $((OPTIND -1))

[[ -z "${BATCH_AUTO_UPDATE}" ]] && BATCH_AUTO_UPDATE=N

#######################################################
# Version Check                                       #
#######################################################
clear

if [[ ! -f "${PARENT}"/env ]]; then
  echo -e "\nCommon env file missing: ${PARENT}/env"
  echo -e "This is a mandatory prerequisite, please install with guild-deploy.sh or manually download from GitHub\n"
  exit 1
fi

. "${PARENT}"/env offline &>/dev/null # ignore any errors, re-sourced later

if [[ ${UPDATE_CHECK} = Y && ${SKIP_UPDATE} != Y ]]; then
  echo "Checking for script updates..."

  # Check availability of checkUpdate function
  if [[ ! $(command -v checkUpdate) ]]; then
    echo -e "\nCould not find checkUpdate function in env, make sure you're using official guild docos for installation!"
    exit 1
  fi

  # check for env update
  ENV_UPDATED=${BATCH_AUTO_UPDATE}
  checkUpdate "${PARENT}"/env N N N
  case $? in
    1) ENV_UPDATED=Y ;;
    2) exit 1 ;;
  esac

  # check for topologyUpdater update
  checkUpdate "${PARENT}"/topologyUpdater.sh ${ENV_UPDATED}
  case $? in
    1) $0 "$@" "-u"; exit 0 ;; # re-launch script with same args skipping update check
    2) exit 1 ;;
  esac

  # source common env variables in case it was updated
  . "${PARENT}"/env offline &>/dev/null
  case $? in
    0) : ;; # ok
    2) echo "continuing with topology update..." ;;
    *) exit 1 ;;
  esac
fi

# Check if old style CUSTOM_PEERS with colon separator is used, if so convert to use commas
if [[ -n ${CUSTOM_PEERS} && ${CUSTOM_PEERS} != *","* ]]; then
  CUSTOM_PEERS=${CUSTOM_PEERS//[:]/,}
fi

if [[ ${TU_PUSH} = "Y" ]]; then
  fail_cnt=0
  while ! blockNo=$(curl -s -f -m ${EKG_TIMEOUT} -H 'Accept: application/json' "http://${EKG_HOST}:${EKG_PORT}/" 2>/dev/null | jq -er '.cardano.node.metrics.blockNum.int.val //0' ); do
    ((fail_cnt++))
    [[ ${fail_cnt} -eq 5 ]] && echo "5 consecutive EKG queries failed, aborting!"
    echo "(${fail_cnt}/5) Failed to grab blockNum from node EKG metrics, sleeping for 30s before retrying... (ctrl-c to exit)"
    sleep 30
  done
fi

if [[ -n ${CNODE_HOSTNAME} && "${CNODE_HOSTNAME}" != "CHANGE ME" ]]; then
  T_HOSTNAME="&hostname=${CNODE_HOSTNAME}"
else
  T_HOSTNAME=''
fi

if [[ ${TU_PUSH} = "Y" ]]; then
  if [[ ${IP_VERSION} = "4" || ${IP_VERSION} = "mix" ]]; then
    curl -s -f -4 "https://api.clio.one/htopology/v1/?port=${CNODE_PORT}&blockNo=${blockNo}&valency=${CNODE_VALENCY}&magic=${NWMAGIC}${T_HOSTNAME}" | tee -a "${LOG_DIR}"/topologyUpdater_lastresult.json
  fi
  if [[ ${IP_VERSION} = "6" || ${IP_VERSION} = "mix" ]]; then
    curl -s -f -6 "https://api.clio.one/htopology/v1/?port=${CNODE_PORT}&blockNo=${blockNo}&valency=${CNODE_VALENCY}&magic=${NWMAGIC}${T_HOSTNAME}" | tee -a "${LOG_DIR}"/topologyUpdater_lastresult.json
  fi
fi

if [[ ${TU_FETCH} = "Y" ]]; then
  if [[ ${P2P_ENABLED} = "true" ]]; then
    echo "INFO: Skipping the TU fetch request because the node is running in P2P mode"
  else
    if [[ ${IP_VERSION} = "4" || ${IP_VERSION} = "mix" ]]; then
      curl -s -f -4 -o "${TOPOLOGY}".tmp "https://api.clio.one/htopology/v1/fetch/?max=${MAX_PEERS}&magic=${NWMAGIC}&ipv=${IP_VERSION}"
    else
      curl -s -f -6 -o "${TOPOLOGY}".tmp "https://api.clio.one/htopology/v1/fetch/?max=${MAX_PEERS}&magic=${NWMAGIC}&ipv=${IP_VERSION}"
    fi
    [[ ! -s "${TOPOLOGY}".tmp ]] && echo "ERROR: The downloaded file is empty!" && exit 1
    if [[ -n "${CUSTOM_PEERS}" ]]; then
      topo="$(cat "${TOPOLOGY}".tmp)"
      IFS='|' read -ra cpeers <<< "${CUSTOM_PEERS}"
      for cpeer in "${cpeers[@]}"; do
        IFS=',' read -ra cpeer_attr <<< "${cpeer}"
        case ${#cpeer_attr[@]} in
          2) addr="${cpeer_attr[0]}"
             port=${cpeer_attr[1]}
             valency=1 ;;
          3) addr="${cpeer_attr[0]}"
             port=${cpeer_attr[1]}
             valency=${cpeer_attr[2]} ;;
          *) echo "ERROR: Invalid Custom Peer definition '${cpeer}'. Please double check CUSTOM_PEERS definition"
             exit 1 ;;
        esac
        if ! isValidIPv4 "${addr}" && ! isValidHostnameOrDomain "${addr}"; then
          echo "ERROR: Invalid IPv4 address or hostname '${addr}'. Please check CUSTOM_PEERS definition"
          continue
        elif [[ ${addr} = *:* ]]; then
          ! isValidIPv6 "${addr}" && echo "ERROR: Invalid IPv6 address '${addr}'. Please check CUSTOM_PEERS definition" && continue
        fi
        ! isNumber ${port} && echo "ERROR: Invalid port number '${port}'. Please check CUSTOM_PEERS definition" && continue
        ! isNumber ${valency} && echo "ERROR: Invalid valency number '${valency}'. Please check CUSTOM_PEERS definition" && continue
        topo=$(jq '.Producers += [{"addr": $addr, "port": $port|tonumber, "valency": $valency|tonumber}]' --arg addr "${addr}" --arg port ${port} --arg valency ${valency} <<< "${topo}")
      done
      echo "${topo}" | jq -r . >/dev/null 2>&1 && echo "${topo}" > "${TOPOLOGY}".tmp
    fi
    mv "${TOPOLOGY}".tmp "${TOPOLOGY}"
  fi
fi
exit 0
