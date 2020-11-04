#!/bin/bash
#shellcheck source=/dev/null

[[ -z "${CNODE_HOME}" ]] && CNODE_HOME="/opt/cardano/cnode"

. "${CNODE_HOME}"/scripts/env

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#CNCLI_DB="${CNODE_HOME}/db/cncli"        # path to sqlite db for cncli
#LIBSODIUM_FORK=/usr/local/lib            # path to IOG fork of libsodium

######################################
# Do NOT modify code below           #
######################################

[[ -z "${CNCLI_DB}" ]] && CNCLI_DB="${CNODE_HOME}/db/cncli"
[[ -z "${LIBSODIUM_FORK}" ]] && LIBSODIUM_FORK=/usr/local/lib
export LD_LIBRARY_PATH="${LIBSODIUM_FORK}:${LD_LIBRARY_PATH}"

[[ ! -f "${CNCLI}" ]] && echo "failed to locate cncli executable, please update to latest env file and run install-cncli.sh!" && exit 1

${CNCLI} sync --host 127.0.0.1 --network-magic "${NWMAGIC}" --port "${CNODE_PORT}" --db "${CNCLI_DB}"