#!/bin/bash
# shellcheck disable=SC2086,SC2034
# shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
######################################

CNODE_HOSTNAME="CHANGE ME"                                # (Optional) Must resolve to the IP you are requesting from
CNODE_LOG_DIR="${CNODE_HOME}/logs/"                       # Folder where your logs will be sent to (must pre-exist)
CNODE_VALENCY=1                                           # (Optional) for multi-IP hostnames
CNODE_TOPOLOGY="${CNODE_HOME}/files/topology.json"        # Destination topology.json file you'd want to write output to
MAX_PEERS=15                                              # Maximum number of peers to return on successful fetch
CUSTOM_PEERS="None"                                       # Additional custom peers to (IP:port[:valency]) to add to your target topology.json, eg: "10.0.0.1:3001|10.0.0.2:3002|relays.mydomain.com:3003:3"

######################################
# Do NOT modify code below           #
######################################

PARENT="$(dirname $0)"
[[ -f "${PARENT}"/.env_branch ]] && BRANCH="$(cat ${PARENT}/.env_branch)" || BRANCH="master"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-b <branch name>]
Topology Updater - Build topology with community pools

-b    Use alternate branch to check for updates - only for testing/development (Default: master)

EOF
  exit 1
}

while getopts :b: opt; do
  case ${opt} in
    b ) BRANCH=${OPTARG}; echo "${BRANCH}" > "${PARENT}"/.env_branch ;;
    \? ) usage ;;
    esac
done
shift $((OPTIND -1))

URL="https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}/scripts/cnode-helper-scripts"
curl -s -m 10 -o "${PARENT}"/env.tmp ${URL}/env
if [[ -f "${PARENT}"/env ]]; then
  if [[ $(grep "_HOME=" "${PARENT}"/env) =~ ^#?([^[:space:]]+)_HOME ]]; then
    vname=$(tr '[:upper:]' '[:lower:]' <<< ${BASH_REMATCH[1]})
    sed -e "s@/opt/cardano/cnode@/opt/cardano/${vname}@g" -e "s@[C]NODE_HOME@${BASH_REMATCH[1]}_HOME@g" -i "${PARENT}"/env.tmp
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
rm -f "${PARENT}"/env.tmp

# source common env variables in case it was updated
if ! . "${PARENT}"/env; then exit 1; fi

blockNo=$(curl -s -m ${EKG_TIMEOUT} -H 'Accept: application/json' "http://${EKG_HOST}:${EKG_PORT}/" 2>/dev/null | jq '.cardano.node.ChainDB.metrics.blockNum.int.val //0' )

# Note: 
# if you run your node in IPv4/IPv6 dual stack network configuration and want announced the 
# IPv4 address only please add the -4 parameter to the curl command below  (curl -4 -s ...)
if [ "${CNODE_HOSTNAME}" != "CHANGE ME" ]; then
  T_HOSTNAME="&hostname=${CNODE_HOSTNAME}"
else
  T_HOSTNAME=''
fi

[[ "${CUSTOM_PEERS}" = "None" ]] && CUSTOM_PEERS_PARAM="" || CUSTOM_PEERS_PARAM="&customPeers=${CUSTOM_PEERS}"

curl -s "https://api.clio.one/htopology/v1/?port=${CNODE_PORT}&blockNo=${blockNo}&valency=${CNODE_VALENCY}&magic=${NWMAGIC}${T_HOSTNAME}" | tee -a $CNODE_LOG_DIR/topologyUpdater_lastresult.json && \
curl -s -o "${CNODE_TOPOLOGY}".tmp "https://api.clio.one/htopology/v1/fetch/?max=${MAX_PEERS}&magic=${NWMAGIC}${CUSTOM_PEERS_PARAM}" && \
mv "${CNODE_TOPOLOGY}".tmp "${CNODE_TOPOLOGY}"


