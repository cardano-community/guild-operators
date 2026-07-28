#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2034
# shellcheck source=/dev/null

PARENT="$(dirname "$0")"

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

usage() {
  cat <<-EOF
		Usage: $(basename "$0") [-b <branch name>] [-f] [-p]
		       $(basename "$0") -d
		       $(basename "$0") systemd install [restart-seconds]
		       $(basename "$0") systemd <remove|status>
		Topology Updater - Build topology with community pools
		LEGACY: topologyUpdater is retained for non-P2P cnode deployments only.

		-f    Disable fetch of a fresh topology file
		-p    Disable node alive push to Topology Updater API
		-u    Skip script update check overriding UPDATE_CHECK value in env
		-b    Use alternate branch to check for updates - only for testing/development (Default: master)
		-d    Install all five topologyUpdater systemd units using the default interval
		systemd
		      Install, remove, or show the status of all five topologyUpdater units.
		      The optional restart interval defaults to 86400 seconds.
		
		EOF
  exit 1
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

topology_systemd_units() {
  printf '%s\n' \
    "${CNODE_VNAME}-tu-push.service" \
    "${CNODE_VNAME}-tu-push.timer" \
    "${CNODE_VNAME}-tu-fetch.service" \
    "${CNODE_VNAME}-tu-restart.service" \
    "${CNODE_VNAME}-tu-restart.timer"
}

deploy_systemd() {
  local interval="${1:-86400}"
  local push_service push_timer fetch_service restart_service restart_timer
  local unit_content

  if [[ ! ${interval} =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: restart-seconds must be a positive integer."
    return 1
  fi
  if [[ ${NODE_IMPLEMENTATION:-cnode} != "cnode" ]]; then
    echo "ERROR: topologyUpdater systemd units are supported only for legacy cnode deployments."
    return 1
  fi
  load_systemd_library || return 1
  echo "WARNING: topologyUpdater is a legacy service for non-P2P cnode deployments."

  push_service="${CNODE_VNAME}-tu-push.service"
  push_timer="${CNODE_VNAME}-tu-push.timer"
  fetch_service="${CNODE_VNAME}-tu-fetch.service"
  restart_service="${CNODE_VNAME}-tu-restart.service"
  restart_timer="${CNODE_VNAME}-tu-restart.timer"

  read -r -d '' unit_content <<-EOF || true
		[Unit]
		Description=Cardano Node - Topology Updater - node alive push

		[Service]
		Type=oneshot
		User=${USER}
		WorkingDirectory=${CNODE_HOME}/scripts
		ExecStart=/bin/bash -l -c "exec ${CNODE_HOME}/scripts/topologyUpdater.sh -f"
		SyslogIdentifier=${CNODE_VNAME}-tu-push
	EOF
  systemd_install_unit \
    "${push_service}" "${unit_content}" \
    "${CNODE_HOME}/scripts/topologyUpdater.sh" "Topology Updater" || return 1

  read -r -d '' unit_content <<-EOF || true
		[Unit]
		Description=Cardano Node - Wake Topology Updater node alive push service once an hour
		BindsTo=${CNODE_VNAME}.service

		[Timer]
		OnActiveSec=1h
		OnUnitInactiveSec=1h
		AccuracySec=1s

		[Install]
		WantedBy=timers.target ${CNODE_VNAME}.service
	EOF
  systemd_install_unit \
    "${push_timer}" "${unit_content}" \
    "${CNODE_HOME}/scripts/topologyUpdater.sh" "Topology Updater" || return 1

  read -r -d '' unit_content <<-EOF || true
		[Unit]
		Description=Cardano Node - Topology Updater - fetches a fresh topology before ${CNODE_VNAME}.service start
		BindsTo=${CNODE_VNAME}.service
		Before=${CNODE_VNAME}.service

		[Service]
		Type=oneshot
		User=${USER}
		WorkingDirectory=${CNODE_HOME}/scripts
		ExecStart=/bin/bash -l -c "exec ${CNODE_HOME}/scripts/topologyUpdater.sh -p"
		ExecStartPost=/bin/sleep 5
		SyslogIdentifier=${CNODE_VNAME}-tu-fetch

		[Install]
		WantedBy=${CNODE_VNAME}.service
	EOF
  systemd_install_unit \
    "${fetch_service}" "${unit_content}" \
    "${CNODE_HOME}/scripts/topologyUpdater.sh" "Topology Updater" || return 1

  read -r -d '' unit_content <<-EOF || true
		[Unit]
		Description=Cardano Node - Topology Updater - restart ${CNODE_VNAME}.service for topology update

		[Service]
		Type=oneshot
		WorkingDirectory=${CNODE_HOME}/scripts
		ExecStart=/bin/bash -c "/bin/systemctl try-restart ${CNODE_VNAME}.service 2>/dev/null || /usr/bin/systemctl try-restart ${CNODE_VNAME}.service 2>/dev/null"
		SyslogIdentifier=${CNODE_VNAME}-tu-restart
	EOF
  systemd_install_unit \
    "${restart_service}" "${unit_content}" \
    "${CNODE_HOME}/scripts/topologyUpdater.sh" "Topology Updater" || return 1

  read -r -d '' unit_content <<-EOF || true
		[Unit]
		Description=Cardano Node - Wake Topology Updater restart service at set interval
		BindsTo=${CNODE_VNAME}.service

		[Timer]
		OnActiveSec=${interval}
		OnUnitInactiveSec=${interval}
		AccuracySec=1s

		[Install]
		WantedBy=timers.target ${CNODE_VNAME}.service
	EOF
  systemd_install_unit \
    "${restart_timer}" "${unit_content}" \
    "${CNODE_HOME}/scripts/topologyUpdater.sh" "Topology Updater" || return 1

  systemd_daemon_reload &&
    systemd_enable_units "${fetch_service}" "${push_timer}" "${restart_timer}" &&
    echo "Topology Updater systemd units deployed successfully."
}

manage_systemd() {
  local action="${1:-}"
  local interval="${2:-86400}"
  local -a units

  mapfile -t units < <(topology_systemd_units)
  case "${action}" in
    install) deploy_systemd "${interval}" ;;
    remove)
      load_systemd_library &&
        systemd_remove_units \
          --owner-token "${CNODE_HOME}/scripts/topologyUpdater.sh" \
          --legacy-token "Topology Updater" \
          "${units[@]}" &&
        echo "Topology Updater systemd units removed successfully."
      ;;
    status)
      load_systemd_library && systemd_status_units "${units[@]}"
      ;;
    *) usage ;;
  esac
}

TU_FETCH=Y
TU_PUSH=Y
SKIP_UPDATE=N
BRANCH_OVERRIDE=""
SYSTEMD_ACTION=""
SYSTEMD_INTERVAL=""

if [[ ${1:-} == "systemd" ]]; then
  SYSTEMD_ACTION="${2}"
  case "${SYSTEMD_ACTION}" in
    install)
      [[ $# -ge 2 && $# -le 3 ]] || usage
      SYSTEMD_INTERVAL="${3:-86400}"
      ;;
    remove|status)
      [[ $# -eq 2 ]] || usage
      SYSTEMD_INTERVAL="86400"
      ;;
    *) usage ;;
  esac
  shift $#
else
  while getopts :dfpub: opt; do
    case ${opt} in
      d ) SYSTEMD_ACTION="install"; SYSTEMD_INTERVAL="86400" ;;
      f ) TU_FETCH=N ;;
      p ) TU_PUSH=N ;;
      u ) SKIP_UPDATE=Y ;;
      b ) BRANCH_OVERRIDE="${OPTARG}" ;;
      \? ) usage ;;
    esac
  done
  shift $((OPTIND -1))
fi

[[ -z "${BATCH_AUTO_UPDATE}" ]] && BATCH_AUTO_UPDATE=N

#######################################################
# Version Check                                       #
#######################################################

if [[ ! -f "${PARENT}"/env ]]; then
  echo -e "\nCommon env file missing: ${PARENT}/env"
  echo -e "This is a mandatory prerequisite, please install with guild-deploy.sh or manually download from GitHub\n"
  exit 1
fi

[[ -n "${BRANCH_OVERRIDE}" ]] && export GUILD_BRANCH_OVERRIDE="${BRANCH_OVERRIDE}"
if [[ -n "${SYSTEMD_ACTION}" ]]; then
  . "${PARENT}"/env definitions
else
  . "${PARENT}"/env offline
fi
case $? in
  0) : ;;
  2) clear ;;
  *) echo "ERROR: Failed to load common env file." && exit 1 ;;
esac

if [[ -n "${BRANCH_OVERRIDE}" ]]; then
  BRANCH="${BRANCH_OVERRIDE}"
  if declare -F deployment_set_branch >/dev/null 2>&1; then
    deployment_set_branch "${BRANCH_OVERRIDE}" || {
      echo "ERROR: Failed to save the branch in ${NODE_HOME:-${CNODE_HOME}}/.deployment.json"
      exit 1
    }
  else
    echo "WARNING: deployment_set_branch is unavailable; using '${BRANCH_OVERRIDE}' for this run only."
  fi
fi

if [[ -n "${SYSTEMD_ACTION}" ]]; then
  manage_systemd "${SYSTEMD_ACTION}" "${SYSTEMD_INTERVAL}"
  exit $?
fi

clear

if [[ ${UPDATE_CHECK} = Y && ${SKIP_UPDATE} != Y ]]; then
  echo "Checking for script updates..."

  if ! declare -F checkCommonRuntimeUpdates >/dev/null 2>&1; then
    echo -e "\nWARNING: Common runtime bundle updater is unavailable; skipping updates."
    echo "Re-run guild-deploy.sh before updating topologyUpdater.sh."
  else
    ENV_UPDATED=${BATCH_AUTO_UPDATE}
    if checkCommonRuntimeUpdates N; then
      common_update_status=0
    else
      common_update_status=$?
    fi
    case "${common_update_status}" in
      0) ;;
      1) ENV_UPDATED=Y ;;
      2) exit 1 ;;
    esac

    # check for topologyUpdater update
    checkUpdate "${PARENT}"/topologyUpdater.sh "${ENV_UPDATED}"
    case $? in
      1) $0 "$@" "-u"; exit 0 ;; # re-launch script with same args skipping update check
      2) exit 1 ;;
    esac
  fi

  # source common env variables in case it was updated
  . "${PARENT}"/env offline &>/dev/null
  env_status=$?
  [[ -n "${BRANCH_OVERRIDE}" ]] && BRANCH="${BRANCH_OVERRIDE}"
  case ${env_status} in
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
