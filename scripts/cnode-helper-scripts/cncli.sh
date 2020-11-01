#!/bin/bash
#shellcheck disable=SC2086
#shellcheck source=/dev/null

[[ -z "${CNODE_HOME}" ]] && CNODE_HOME="/opt/cardano/cnode"

. "${CNODE_HOME}"/scripts/env

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#CNCLI_DB="${CNODE_HOME}/db/cncli"        # path to sqlite db for cncli

######################################
# Do NOT modify code below           #
######################################

[[ -z "${CNCLI_DB}" ]] && CNCLI_DB="${CNODE_HOME}/db/cncli"

[[ ! -f ${CNCLI} ]] && echo "failed to locate cncli executable, please update to latest env file and run install-cncli.sh!" && exit 1

${CNCLI} sync --host 127.0.0.1 --network-magic ${NWMAGIC} --port ${CNODE_PORT} --db "${CNCLI_DB}"