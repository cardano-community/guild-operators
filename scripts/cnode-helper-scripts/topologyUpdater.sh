#!/bin/bash
# shellcheck disable=SC2086,SC2034

######################################
# User Variables - Change as desired #
######################################

CNODE_HOSTNAME="CHANGE ME"                                # (Optional) Must resolve to the IP you are requesting from
CNODE_LOG_DIR="${CNODE_HOME}/logs/"                       # Folder where your logs will be sent to (must pre-exist)
CNODE_VALENCY=1                                           # (Optional) for multi-IP hostnames

######################################
# Do NOT modify code below           #
######################################

PARENT="$(dirname $0)"
BRANCH="master"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-a]
Topology Updater - Build topology with community pools

-a    Use alpha branch to check for updates - only for testing/development

EOF
  exit 1
}

while getopts :a opt; do
  case ${opt} in
    a ) BRANCH="alpha" ;;
    \? ) usage ;;
    esac
done
shift $((OPTIND -1))

URL="https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}/scripts/cnode-helper-scripts"
curl -s -m 10 -o "${PARENT}"/env.tmp ${URL}/env
if [[ -f "${PARENT}"/env ]]; then
  TEMPL_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env)
  TEMPL2_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env.tmp)
  if [[ "$(echo ${TEMPL_CMD} | sha256sum)" != "$(echo ${TEMPL2_CMD} | sha256sum)" ]]; then
    cp "${PARENT}"/env "${PARENT}/env.bkp_$(date +%s)"
    STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/env)
    printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL2_CMD" > "${PARENT}"/env.tmp
    mv "${PARENT}"/env.tmp "${PARENT}"/env
  fi
else
  mv "${PARENT}"/env.tmp "${PARENT}"/env
fi
rm -f "${PARENT}"/env.tmp

blockNo=$(cardano-cli shelley query tip ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} | jq -r .blockNo )

# Note: 
# if you run your node in IPv4/IPv6 dual stack network configuration and want announced the 
# IPv4 address only please add the -4 parameter to the curl command below  (curl -4 -s ...)
if [ "${CNODE_HOSTNAME}" != "CHANGE ME" ]; then
  T_HOSTNAME="&hostname=${CNODE_HOSTNAME}"
else
  T_HOSTNAME=''
fi

curl -s "https://api.clio.one/htopology/v1/?port=${CNODE_PORT}&blockNo=${blockNo}&valency=${CNODE_VALENCY}&magic=${NWMAGIC}${T_HOSTNAME}" | tee -a $CNODE_LOG_DIR/topologyUpdater_lastresult.json
