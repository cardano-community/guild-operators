#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

. "$(dirname $0)"/env offline

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#CPU_CORES=2              # Number of CPU cores cardano-node process has access to (please don't set higher than physical core count, 2-4 recommended)
#CNODE_LISTEN_IP4=0.0.0.0 # IP to use for listening (only applicable to Node Connection Port) for IPv4
#CNODE_LISTEN_IP6=::      # IP to use for listening (only applicable to Node Connection Port) for IPv6

######################################
# Do NOT modify code below           #
######################################

[[ -z ${CNODE_LISTEN_IP4} ]] && CNODE_LISTEN_IP4=0.0.0.0
[[ -z ${CNODE_LISTEN_IP6} ]] && CNODE_LISTEN_IP6=::

if [[ -S "${CARDANO_NODE_SOCKET_PATH}" ]]; then
  if pgrep -f "$(basename ${CNODEBIN}).*.${CARDANO_NODE_SOCKET_PATH}"; then
     echo "ERROR: A Cardano node is already running, please terminate this node before starting a new one with this script."
     exit 1
  else
    echo "WARN: A prior running Cardano node was not cleanly shutdown, socket file still exists. Cleaning up."
    unlink "${CARDANO_NODE_SOCKET_PATH}"
  fi
fi

[[ -n ${CPU_CORES} ]] && CPU_RUNTIME=( "+RTS" "-N${CPU_CORES}" "-RTS" ) || CPU_RUNTIME=()

[[ ! -d "${LOG_DIR}/archive" ]] && mkdir -p "${LOG_DIR}/archive"

[[ $(find "${LOG_DIR}"/*.json 2>/dev/null | wc -l) -gt 0 ]] && mv "${LOG_DIR}"/*.json "${LOG_DIR}"/archive/

host_addr=()
[[ ${IP_VERSION} = "4" || ${IP_VERSION} = "mix" ]] && host_addr+=("--host-addr" "${CNODE_LISTEN_IP4}")
[[ ${IP_VERSION} = "6" || ${IP_VERSION} = "mix" ]] && host_addr+=("--host-ipv6-addr" "${CNODE_LISTEN_IP6}")

if [[ -f "${POOL_DIR}/${POOL_OPCERT_FILENAME}" && -f "${POOL_DIR}/${POOL_VRF_SK_FILENAME}" && -f "${POOL_DIR}/${POOL_HOTKEY_SK_FILENAME}" ]]; then
  "${CNODEBIN}" "${CPU_RUNTIME[@]}" run \
    --topology "${TOPOLOGY}" \
    --config "${CONFIG}" \
    --database-path "${DB_DIR}" \
    --socket-path "${CARDANO_NODE_SOCKET_PATH}" \
    --shelley-kes-key "${POOL_DIR}/${POOL_HOTKEY_SK_FILENAME}" \
    --shelley-vrf-key "${POOL_DIR}/${POOL_VRF_SK_FILENAME}" \
    --shelley-operational-certificate "${POOL_DIR}/${POOL_OPCERT_FILENAME}" \
    --port ${CNODE_PORT} \
    "${host_addr[@]}"
else
  "${CNODEBIN}" "${CPU_RUNTIME[@]}" run \
    --topology "${TOPOLOGY}" \
    --config "${CONFIG}" \
    --database-path "${DB_DIR}" \
    --socket-path "${CARDANO_NODE_SOCKET_PATH}" \
    --port ${CNODE_PORT} \
    "${host_addr[@]}"
fi
