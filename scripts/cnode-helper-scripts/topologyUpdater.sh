#!/bin/bash
# shellcheck disable=SC2086,SC2034
# shellcheck source=/dev/null

PARENT="$(dirname $0)"
[[ -f "${PARENT}"/env ]] && . "${PARENT}"/env offline

######################################
# User Variables - Change as desired #
######################################

CNODE_HOSTNAME="CHANGE ME"  # (Optional) Must resolve to the IP you are requesting from
CNODE_VALENCY=1             # (Optional) for multi-IP hostnames
MAX_PEERS=15                # Maximum number of peers to return on successful fetch
#CUSTOM_PEERS="None"        # Additional custom peers to (IP:port[:valency]) to add to your target topology.json
                            # eg: "10.0.0.1:3001|10.0.0.2:3002|relays.mydomain.com:3003:3"
#BATCH_AUTO_UPDATE=N        # Set to Y to automatically update the script if a new version is available without user interaction

######################################
# Do NOT modify code below           #
######################################

PARENT="$(dirname $0)"
[[ -f "${PARENT}"/.env_branch ]] && BRANCH="$(cat ${PARENT}/.env_branch)" || BRANCH="master"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-b <branch name>] [-f] [-p]
Topology Updater - Build topology with community pools

-f    Disable fetch of a fresh topology file
-p    Disable node alive push to Topology Updater API
-b    Use alternate branch to check for updates - only for testing/development (Default: master)

EOF
  exit 1
}

TU_FETCH='Y'
TU_PUSH='Y'

while getopts :fpb: opt; do
  case ${opt} in
    f ) TU_FETCH='N' ;;
    p ) TU_PUSH='N' ;;
    b ) BRANCH=${OPTARG}; echo "${BRANCH}" > "${PARENT}"/.env_branch ;;
    \? ) usage ;;
  esac
done
shift $((OPTIND -1))

[[ -z "${BATCH_AUTO_UPDATE}" ]] && BATCH_AUTO_UPDATE=N

# Check if update is available
URL="https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}/scripts/cnode-helper-scripts"
if curl -s -m 10 -o "${PARENT}"/topologyUpdater.sh.tmp ${URL}/topologyUpdater.sh && curl -s -m ${CURL_TIMEOUT} -o "${PARENT}"/env.tmp ${URL}/env && [[ -f "${PARENT}"/topologyUpdater.sh.tmp && -f "${PARENT}"/env.tmp ]]; then
  if [[ -f "${PARENT}"/env ]]; then
    if [[ $(grep "_HOME=" "${PARENT}"/env) =~ ^#?([^[:space:]]+)_HOME ]]; then
      vname=$(tr '[:upper:]' '[:lower:]' <<< "${BASH_REMATCH[1]}")
    else
      echo -e "\nFailed to get cnode instance name from env file, aborting!\n"
      rm -f "${PARENT}"/topologyUpdater.sh.tmp
      rm -f "${PARENT}"/env.tmp
      exit 1
    fi
    sed -e "s@/opt/cardano/[c]node@/opt/cardano/${vname}@g" -e "s@[C]NODE_HOME@${BASH_REMATCH[1]}_HOME@g" -i "${PARENT}"/topologyUpdater.sh.tmp -i "${PARENT}"/env.tmp
    TU_TEMPL=$(awk '/^# Do NOT modify/,0' "${PARENT}"/topologyUpdater.sh)
    TU_TEMPL2=$(awk '/^# Do NOT modify/,0' "${PARENT}"/topologyUpdater.sh.tmp)
    ENV_TEMPL=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env)
    ENV_TEMPL2=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env.tmp)
    if [[ "$(echo ${TU_TEMPL} | sha256sum)" != "$(echo ${TU_TEMPL2} | sha256sum)" || "$(echo ${ENV_TEMPL} | sha256sum)" != "$(echo ${ENV_TEMPL2} | sha256sum)" ]]; then
      . "${PARENT}"/env offline &>/dev/null # source in offline mode and ignore errors to get some common functions, sourced at a later point again
      if [[ ${BATCH_AUTO_UPDATE} = 'Y' ]] || { [[ -t 1 ]] && getAnswer "\nA new version is available, do you want to upgrade?"; }; then
        cp "${PARENT}"/topologyUpdater.sh "${PARENT}/topologyUpdater.sh_bkp$(date +%s)"
        cp "${PARENT}"/env "${PARENT}/env_bkp$(date +%s)"
        TU_STATIC=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/topologyUpdater.sh)
        ENV_STATIC=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/env)
        printf '%s\n%s\n' "$TU_STATIC" "$TU_TEMPL2" > "${PARENT}"/topologyUpdater.sh.tmp
        printf '%s\n%s\n' "$ENV_STATIC" "$ENV_TEMPL2" > "${PARENT}"/env.tmp
        {
          mv -f "${PARENT}"/topologyUpdater.sh.tmp "${PARENT}"/topologyUpdater.sh && \
          mv -f "${PARENT}"/env.tmp "${PARENT}"/env && \
          chmod 755 "${PARENT}"/topologyUpdater.sh "${PARENT}"/env && \
          echo -e "\nUpdate applied successfully, please run topologyUpdater again!\n" && \
          exit 0; 
        } || {
          echo -e "\n${FG_RED}Update failed!${NC}\n\nplease install topologyUpdater.sh & env with prereqs.sh or manually download from GitHub" && \
          rm -f "${PARENT}"/topologyUpdater.sh.tmp && \
          rm -f "${PARENT}"/env.tmp && \
          exit 1;
        }
      fi
    fi
  else
    mv "${PARENT}"/env.tmp "${PARENT}"/env
    rm -f "${PARENT}"/topologyUpdater.sh.tmp
    echo -e "\nCommon env file downloaded: ${PARENT}/env"
    echo -e "This is a mandatory prerequisite, please set variables accordingly in User Variables section in the env file and restart topologyUpdater.sh\n"
    exit 0
  fi
else # Download failed, ignore update check
  rm -f "${PARENT}"/topologyUpdater.sh.tmp
  rm -f "${PARENT}"/env.tmp
fi
if [[ ! -f "${PARENT}"/env ]]; then
  echo -e "\nCommon env file missing: ${PARENT}/env"
  echo -e "This is a mandatory prerequisite, please install with prereqs.sh or manually download from GitHub\n"
  exit 1
fi

# source common env variables in case it was updated and run in offline mode, even for TU_PUSH mode as this will be cought by failed EKG query
if ! . "${PARENT}"/env offline; then exit 1; fi

if [[ ${TU_PUSH} = "Y" ]]; then
  fail_cnt=0
  while ! blockNo=$(curl -s -m ${EKG_TIMEOUT} -H 'Accept: application/json' "http://${EKG_HOST}:${EKG_PORT}/" 2>/dev/null | jq -er '.cardano.node.metrics.blockNum.int.val //0' ); do
    ((fail_cnt++))
    [[ ${fail_cnt} -eq 5 ]] && echo "5 consecutive EKG queries failed, aborting!"
    echo "(${fail_cnt}/5) Failed to grab blockNum from node EKG metrics, sleeping for 30s before retrying... (ctrl-c to exit)"
    sleep 30
  done
fi

# Note: 
# if you run your node in IPv4/IPv6 dual stack network configuration and want announced the 
# IPv4 address only please add the -4 parameter to the curl command below  (curl -4 -s ...)
if [ "${CNODE_HOSTNAME}" != "CHANGE ME" ]; then
  T_HOSTNAME="&hostname=${CNODE_HOSTNAME}"
else
  T_HOSTNAME=''
fi

[[ -z "${CUSTOM_PEERS}" ]] && CUSTOM_PEERS_PARAM="" || CUSTOM_PEERS_PARAM="&customPeers=${CUSTOM_PEERS}"

[[ ${TU_PUSH} = "Y" ]] && curl -s -f "https://api.clio.one/htopology/v1/?port=${CNODE_PORT}&blockNo=${blockNo}&valency=${CNODE_VALENCY}&magic=${NWMAGIC}${T_HOSTNAME}" | tee -a "${LOG_DIR}"/topologyUpdater_lastresult.json
[[ ${TU_FETCH} = "Y" ]] && curl -s -f -o "${TOPOLOGY}".tmp "https://api.clio.one/htopology/v1/fetch/?max=${MAX_PEERS}&magic=${NWMAGIC}${CUSTOM_PEERS_PARAM}" && \
mv "${TOPOLOGY}".tmp "${TOPOLOGY}"

exit 0
