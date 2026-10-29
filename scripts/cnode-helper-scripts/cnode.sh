#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#CPU_CORES=4              # Number of CPU cores cardano-node process has access to (please don't set higher than physical core count, recommended to set atleast to 4)
#CNODE_LISTEN_IP4=0.0.0.0 # IP to use for listening (only applicable to Node Connection Port) for IPv4
#CNODE_LISTEN_IP6=::      # IP to use for listening (only applicable to Node Connection Port) for IPv6

######################################
# Do NOT modify code below           #
######################################

#####################
# Functions         #
#####################

usage() {
  cat <<-EOF

		Usage: $(basename "$0") [-d|-s]
		       $(basename "$0") systemd <install|remove|status|reload>

		Cardano Node wrapper script !!
		-d    Deploy cnode as a systemd service
		-s    Stop cnode using SIGINT
		systemd
		      Install, remove, or show the status of the cnode service
		      reload sends SIGHUP to the running service: the node re-reads its
		      topology and, on a block producer, its KES key, VRF key and op.cert

		EOF
  exit 1
}

set_defaults() {
  [[ -z ${CPU_CORES} ]] && CPU_CORES=4
  [[ -n ${CPU_CORES} ]] && CPU_RUNTIME=( "+RTS" "-N${CPU_CORES}" "-RTS" )
  [[ -z ${CNODE_LISTEN_IP4} ]] && CNODE_LISTEN_IP4=0.0.0.0
  [[ -z ${CNODE_LISTEN_IP6} ]] && CNODE_LISTEN_IP6=::
  host_addr=()
  [[ ${IP_VERSION} = "4" || ${IP_VERSION} = "mix" ]] && host_addr+=("--host-addr" "${CNODE_LISTEN_IP4}")
  [[ ${IP_VERSION} = "6" || ${IP_VERSION} = "mix" ]] && host_addr+=("--host-ipv6-addr" "${CNODE_LISTEN_IP6}")
}

check_config_sanity() {
  BYGENHASH=$("${CCLI}" byron genesis print-genesis-hash --genesis-json "${BYRON_GENESIS_JSON}" 2>/dev/null)
  BYGENHASHCFG=$(jq '.ByronGenesisHash' <"${CONFIG}" 2>/dev/null)
  SHGENHASH=$("${CCLI}" hash genesis-file --genesis "${GENESIS_JSON}" 2>/dev/null)
  SHGENHASHCFG=$(jq '.ShelleyGenesisHash' <"${CONFIG}" 2>/dev/null)
  ALGENHASH=$("${CCLI}" hash genesis-file --genesis "${ALONZO_GENESIS_JSON}" 2>/dev/null)
  ALGENHASHCFG=$(jq '.AlonzoGenesisHash' <"${CONFIG}" 2>/dev/null)
  CWGENHASH=$("${CCLI}" hash genesis-file --genesis "${CONWAY_GENESIS_JSON}" 2>/dev/null)
  CWGENHASHCFG=$(jq '.ConwayGenesisHash' <"${CONFIG}" 2>/dev/null)
  # If hash are missing/do not match, add that to the end of config. We could have sorted it based on logic, but that would mess up sdiff comparison outputs
  if [[ "${BYGENHASH}" != "${BYGENHASHCFG}" ]] || [[ "${SHGENHASH}" != "${SHGENHASHCFG}" ]] || [[ "${ALGENHASH}" != "${ALGENHASHCFG}" ]] || [[ "${CWGENHASH}" != "${CWGENHASHCFG}" ]]; then
    cp "${CONFIG}" "${CONFIG}".tmp
    jq --arg BYGENHASH ${BYGENHASH} --arg SHGENHASH ${SHGENHASH} --arg ALGENHASH ${ALGENHASH} --arg CWGENHASH ${CWGENHASH} '.ByronGenesisHash = $BYGENHASH | .ShelleyGenesisHash = $SHGENHASH | .AlonzoGenesisHash = $ALGENHASH | .ConwayGenesisHash = $CWGENHASH' <"${CONFIG}" >"${CONFIG}".tmp
    [[ -s "${CONFIG}".tmp ]] && mv -f "${CONFIG}".tmp "${CONFIG}"
  fi
}

pre_startup_sanity() {
  # Check if node is already running, or if stale socket file is left
  if [[ -S "${CARDANO_NODE_SOCKET_PATH}" ]]; then
    if pgrep -f "$(basename ${CNODEBIN}).*.${CARDANO_NODE_SOCKET_PATH}"; then
       echo "ERROR: A Cardano node is already running, please terminate this node before starting a new one with this script."
       exit 1
    else
      unlink "${CARDANO_NODE_SOCKET_PATH}"
      echo "INFO: Cleaned-up stale socket file"
    fi
  fi
  check_config_sanity
}

mithril_snapshot_download() {
  [[ -z "${MITHRIL_CLIENT}" ]] && MITHRIL_CLIENT="${CNODE_HOME}"/scripts/mithril-client.sh
  if [[ ! -f "${MITHRIL_CLIENT}" ]] || [[ ! -e "${MITHRIL_CLIENT}" ]]; then 
    echo "ERROR: Could not locate mithril-client.sh script or script is not executable. Skipping mithril cardano-db snapshot download!!"
  else
    "${MITHRIL_CLIENT}" -u cardano-db download
  fi
}

stop_node() {
  CNODE_PID=$(pgrep -fn "$(basename ${CNODEBIN}).*.--port ${CNODE_PORT}" 2>/dev/null) # env was only called in offline mode
  kill -2 ${CNODE_PID} 2>/dev/null
  # touch clean "${CNODE_HOME}"/db/clean # Disabled as it's a bit hacky, but only runs when SIGINT is passed to node process. Should not be needed if node does it's job
  printf "  Sending SIGINT to cardano-node process.."
  sleep 5
  exit 0
}

load_systemd_library() {
  local systemd_library="${PARENT}/lib/systemd.library"
  [[ -f "${systemd_library}" ]] || systemd_library="${PARENT}/systemd.library"
  [[ -f "${systemd_library}" ]] || systemd_library="${PARENT}/../common-helper-scripts/lib/systemd.library"
  if [[ ! -f "${systemd_library}" ]]; then
    echo "ERROR: systemd.library is missing. Re-run the deployment script to install shared helpers."
    return 1
  fi
  # shellcheck disable=SC1091
  . "${systemd_library}"
}

deploy_systemd() {
  local unit_name="${CNODE_VNAME}.service"
  local unit_content

  load_systemd_library || return 1
  echo "Deploying ${CNODE_VNAME} as systemd service.."
  read -r -d '' unit_content <<-EOF || true
		[Unit]
		Description=Cardano Node
		Wants=network-online.target
		After=network-online.target
		StartLimitIntervalSec=600
		StartLimitBurst=5

		[Service]
		Type=simple
		Restart=on-failure
		RestartSec=60
		User=${USER}
		LimitNOFILE=1048576
		WorkingDirectory=${CNODE_HOME}/scripts
		ExecStart=/bin/bash -l -c "exec ${CNODE_HOME}/scripts/cnode.sh"
		ExecStop=/bin/bash -l -c "exec ${CNODE_HOME}/scripts/cnode.sh -s"
		KillSignal=SIGINT
		SuccessExitStatus=143
		SyslogIdentifier=${CNODE_VNAME}
		TimeoutStopSec=60

		[Install]
		WantedBy=multi-user.target
	EOF
  systemd_install_unit "${unit_name}" "${unit_content}" "${CNODE_HOME}/scripts/cnode.sh" &&
    systemd_daemon_reload &&
    systemd_enable_units "${unit_name}" &&
    echo "${unit_name} deployed successfully!!"
}

# cardano-node re-reads its topology and block-forging credentials on SIGHUP.
# A SIGHUP that reaches cnode.sh itself, while it still prepares the start
# (for example a Mithril download), would end the startup instead.
reload_systemd() {
  local unit_name="${CNODE_VNAME}.service"
  local node_name main_pid process_name

  load_systemd_library || return 1
  if ! command -v "${SYSTEMCTL_BIN}" >/dev/null 2>&1; then
    echo "ERROR: systemd is required to reload ${unit_name}."
    return 1
  fi
  if [[ "$("${SYSTEMCTL_BIN}" show --property LoadState --value "${unit_name}" 2>/dev/null)" != "loaded" ]]; then
    echo "ERROR: ${unit_name} is not deployed. Install it with: $(basename "$0") systemd install"
    return 1
  fi
  main_pid="$("${SYSTEMCTL_BIN}" show --property MainPID --value "${unit_name}" 2>/dev/null)"
  if [[ ! "${main_pid}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: ${unit_name} is not running. Start it with: sudo systemctl start ${unit_name}"
    return 1
  fi
  node_name="$(basename "${CNODEBIN:-cardano-node}")"
  if ! process_name="$(cat "${CNODE_PROCFS_ROOT:-/proc}/${main_pid}/comm" 2>/dev/null)"; then
    echo "ERROR: Cannot inspect the main process of ${unit_name}; run the reload as the service user or root."
    return 1
  fi
  # The kernel shortens process names to 15 characters.
  if [[ "${process_name}" != "${node_name:0:15}" ]]; then
    echo "ERROR: ${unit_name} is still starting (PID ${main_pid} runs ${process_name}, not ${node_name}). Try again once the node runs."
    return 1
  fi
  if ! kill -HUP "${main_pid}" 2>/dev/null && ! systemd_as_root kill -HUP "${main_pid}"; then
    echo "ERROR: Could not send SIGHUP to ${unit_name} (PID ${main_pid})."
    return 1
  fi
  echo "Sent SIGHUP to ${unit_name} (PID ${main_pid}). The node re-reads its topology and, when it runs as a block producer, its KES key, VRF key and operational certificate."
}

manage_systemd() {
  local action="${1:-}"
  local unit_name="${CNODE_VNAME}.service"

  case "${action}" in
    install) deploy_systemd ;;
    reload) reload_systemd ;;
    remove)
      load_systemd_library &&
        systemd_remove_units --owner-token "${CNODE_HOME}/scripts/cnode.sh" "${unit_name}" &&
        echo "${unit_name} removed successfully."
      ;;
    status)
      load_systemd_library && systemd_status_units "${unit_name}"
      ;;
    *) usage ;;
  esac
}

###################
# Execution       #
###################

# Parse command line options
SYSTEMD_ACTION=""
if [[ ${1:-} == "systemd" ]]; then
  [[ $# -eq 2 ]] || usage
  SYSTEMD_ACTION="${2}"
  shift 2
fi
while getopts :ds opt; do
  case ${opt} in
    d ) DEPLOY_SYSTEMD="Y" ;;
    s ) STOP_NODE="Y" ;;
    \? ) usage ;;
  esac
done

[[ ${0} != '-bash' ]] && PARENT="$(dirname $0)" || PARENT="$(pwd)"
# Check if env file is missing in current folder (no update checks as will mostly run as daemon), source env if present
[[ ! -f "${PARENT}"/env ]] && echo -e "\nCommon env file missing in \"${PARENT}\", please ensure latest guild-deploy.sh was run and this script is being run from ${CNODE_HOME}/scripts folder! \n" && exit 1
if [[ "${SYSTEMD_ACTION}" == "remove" || "${SYSTEMD_ACTION}" == "status" || "${SYSTEMD_ACTION}" == "reload" ]]; then
  . "${PARENT}"/env definitions
else
  . "${PARENT}"/env offline
fi
case $? in
  1) echo -e "ERROR: Failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" && exit 1;;
  2) clear ;;
esac

[[ "${STOP_NODE}" == "Y" ]] && stop_node

# Set defaults and do basic sanity checks
set_defaults
if [[ -n "${SYSTEMD_ACTION}" ]]; then
  manage_systemd "${SYSTEMD_ACTION}"
  exit $?
fi
#Deploy systemd if -d argument was specified
if [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  deploy_systemd && exit 0
  exit 2
fi
pre_startup_sanity

# Download the latest mithril snapshot before starting node
if [[ "${MITHRIL_DOWNLOAD}" == "Y" ]]; then
  mithril_snapshot_download
fi

# Run Node
if [[ -f "${POOL_DIR}/${POOL_OPCERT_FILENAME}" && -f "${POOL_DIR}/${POOL_VRF_SK_FILENAME}" && -f "${POOL_DIR}/${POOL_HOTKEY_SK_FILENAME}" ]]; then
  exec "${CNODEBIN}" "${CPU_RUNTIME[@]}" run \
    --topology "${TOPOLOGY}" \
    --config "${CONFIG}" \
    --database-path "${DB_DIR}" \
    --socket-path "${CARDANO_NODE_SOCKET_PATH}" \
    --shelley-kes-key "${POOL_DIR}/${POOL_HOTKEY_SK_FILENAME}" \
    --shelley-vrf-key "${POOL_DIR}/${POOL_VRF_SK_FILENAME}" \
    --shelley-operational-certificate "${POOL_DIR}/${POOL_OPCERT_FILENAME}" \
    --port ${CNODE_PORT} \
    ${MEMPOOL_OVERRIDE} "${host_addr[@]}"
else
  exec "${CNODEBIN}" "${CPU_RUNTIME[@]}" run \
    --topology "${TOPOLOGY}" \
    --config "${CONFIG}" \
    --database-path "${DB_DIR}" \
    --socket-path "${CARDANO_NODE_SOCKET_PATH}" \
    --port ${CNODE_PORT} \
    ${MEMPOOL_OVERRIDE} "${host_addr[@]}"
fi
