#!/usr/bin/env bash
#shellcheck disable=SC2034,SC1090 source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#TIP_DIFF=600                                                  # Maximum tolerance in seconds for tip to be apart before marking instance as not available to serve requests
#APIPATH=rpc                                                   # Default API path (without start/end slashes) to serve URL endpoints
#API_COMPARE="http://127.0.0.1:8050"                           # Source to be used for comparing RPC endpoint structure against. This variable only impacts failover "locally".
                                                               # Any changes here does not impact your nodes availability remotely, preventing loop of connections within proxies
#API_STRUCT_DEFINITION="https://api.koios.rest/koiosapi.yaml"  # The Doc URL that is to be considered as source of truth - only to be changed if not working with alpha branch
#LOCAL_SPEC="$(dirname $0)/../files/koiosapi.yaml"             # Local copy of downloaded specs (downloaded hourly from API_STRUCT_DEFINITION) file

######################################
# Do NOT modify code below           #
######################################

function set_defaults() {
  [[ -z "${TIP_DIFF}" ]] && TIP_DIFF=600
  [[ -z "${APIPATH}" ]] && APIPATH=rpc
  [[ -z "${API_COMPARE}" ]] && API_COMPARE="http://127.0.0.1:8050"
  [[ -z "${API_STRUCT_DEFINITION}" ]] && API_STRUCT_DEFINITION="https://api.koios.rest/koiosapi.yaml"
  [[ -z "${LOCAL_SPEC}" ]] && LOCAL_SPEC="${PARENT}/../files/koiosapi.yaml"
  [[ "${HAPROXY_SERVER_SSL}" == 1 ]] && SCHEME="https" || SCHEME="http"
  if [[ $# == 2 ]]; then
    GURL="${SCHEME}://${1}:${2}"
  else
    GURL="${SCHEME}://${HAPROXY_SERVER_ADDR}:${HAPROXY_SERVER_PORT}"
  fi
  URLRPC="${GURL}/${APIPATH}"
}

function chk_upd() {
  # Check if the update was polled within past hour
  curr_hour=$(date +%H)
  if [[ ! -f "${PARENT}"/.last_grest_poll ]]; then
    echo "${curr_hour}" > "${PARENT}"/.last_grest_poll
    curl -sfkL "${API_STRUCT_DEFINITION}" -o "${LOCAL_SPEC}" 2>/dev/null
  else
    last_hour=$(cat "${PARENT}"/.last_grest_poll)
    [[ "${curr_hour}" == "${last_hour}" ]] && SKIP_UPDATE=Y || echo "${curr_hour}" > "${PARENT}"/.last_grest_poll
  fi
  if [[ ! -f "${PARENT}"/env ]]; then
    echo -e "\nCommon env file missing: ${PARENT}/env"
    echo -e "This is a mandatory prerequisite, please install with guild-deploy.sh or manually download from GitHub\n"
    exit 1
  fi

  . "${PARENT}"/env offline &>/dev/null
  [[ "${SKIP_UPDATE}" == "Y" ]] && return 0
  if [[ ! $(command -v checkUpdate) ]]; then
    echo -e "\nCould not find checkUpdate function in env, make sure you're using official guild docos for installation!"
    exit 1
  fi
  
  curl -sfkL "${API_STRUCT_DEFINITION}" -o "${LOCAL_SPEC}" 2>/dev/null

  checkUpdate "${PARENT}"/grest-poll.sh Y N N grest-helper-scripts
  [[ "$?" == "2" ]] && echo "ERROR: checkUpdate Failed" && exit 1
}

function log_err() {
  [[ "${DEBUG_MODE}" == "1" ]] && echo "$(date +%DT%T) - ERROR: ${HAPROXY_SERVER_NAME}" "$@"
  echo "$(date +%DT%T) - ERROR: ${HAPROXY_SERVER_NAME}" "$@" >> "${LOG_DIR}"/grest-poll.sh_"$(date +%d%m%y)"
}

function optexit() {
  [[ "${DEBUG_MODE}" != "1" ]] && exit 1
}

function usage() {
  echo -e "\nUsage: $(basename "$0") <server IP> <server port> [-d]\n"
  echo -e "Polling script used by haproxy to query 'server IP' at 'server Port', and perform health checks. Use '-d' parameter to run all health checks.\n\n"
  exit 1
}

function chk_version() {
  ctrl_tbl=$(curl -skL "${GURL}/control_table")
  instance_vr=$(jq -r 'map(select(.key == "version"))[0].last_value' 2>/dev/null <<< "${ctrl_tbl}")
  monitor_vr=$(grep ^\ \ version "${LOCAL_SPEC}" |awk '{print $2}' 2>/dev/null)

  if [[ -z "${instance_vr}" ]] || [[ "${instance_vr}" == "[]" ]]; then
    log_err "Could not fetch the grest version for ${GURL} using control_table endpoint (response received: ${instance_vr})!!"
    optexit
  elif [[ "${instance_vr}" != "${monitor_vr}" ]]; then
    log_err "Version mismatch: ${GURL} is at version : ${instance_vr} while ${API_STRUCT_DEFINITION} (cached) is on version: ${monitor_vr}!!"
    optexit
  fi
}

function chk_tip() {
  read -ra tip <<< "$(curl -m 2 -sfkL "${URLRPC}/tip" 2>/dev/null | jq -r '[
    .[0].epoch_no // 0,
    .[0].abs_slot //0,
    .[0].epoch_slot //0,
    .[0].block_no //0,
    .[0].block_time // 0
  ] | @tsv' )"
  currtip=$(date +%s)
  [[ ${tip[4]} =~ ^[0-9.]+$ ]] && dbtip=$(cut -d. -f1 <<< "${tip[4]}") || dbtip=$(date --date "${tip[4]}+0" +%s)
  if [[ -z "${dbtip}" ]] || [[ $(( currtip - dbtip )) -gt ${TIP_DIFF} ]] ; then
    log_err "${URLRPC}/tip endpoint did not provide a timestamp that's within ${TIP_DIFF} seconds - Tip: ${currtip}, DB Tip: ${dbtip}, Difference: $(( currtip - dbtip ))"
    optexit
  else
    epoch=${tip[0]}
    abs_slot=${tip[1]}
    epoch_slot=${tip[2]}
    block_no=${tip[3]}
  fi
}

function chk_rpc_struct() {
  srvr_spec="$(curl -skL "${1}" | jq '[leaf_paths as $p | { "key": $p | map(tostring) | join("_"), "value": getpath($p) }] | from_entries' | awk '{print $1 " " $2}' | grep -e ^\"paths -e ^\"parameters -e ^\"definitions 2>/dev/null)"
  api_endpts="$(grep ^\ \ / "${LOCAL_SPEC}" | awk '{print $1}' | sed -e 's#:##' | sort)"
  for endpt in ${api_endpts}
  do
    echo "${srvr_spec}" | grep -e "paths.*.${endpt}"
  done
}

function chk_rpcs() {
  instance_rpc_cksum="$(chk_rpc_struct "${GURL}" | sort | grep -v -e description\"\$ -e summary\"\$ | tee "${PARENT}"/.dltarget | shasum -a 256)"
  monitor_rpc_cksum="$(chk_rpc_struct "${API_COMPARE}" | sort | grep -v -e description\"\$ -e summary\"\$ | tee "${PARENT}"/.dlsource | shasum -a 256)"
  if [[ "${instance_rpc_cksum}" != "${monitor_rpc_cksum}" ]]; then
    log_err "The specs returned by ${GURL} do not seem to match ${API_COMPARE} for endpoints mentioned at: ${API_STRUCT_DEFINITION}"
    optexit
  fi
}

function chk_cache_status() {
  last_stakedist_block=$(jq -r 'map(select(.key == "stake_distribution_lbh"))[0].last_value' 2>/dev/null <<< "${ctrl_tbl}")
  last_poolhist_update=$(jq -r 'map(select(.key == "pool_history_cache_last_updated"))[0].last_value' 2>/dev/null <<< "${ctrl_tbl}")
  last_actvstake_epoch=$(jq -r 'map(select(.key == "last_active_stake_validated_epoch"))[0].last_value' 2>/dev/null <<< "${ctrl_tbl}")
  if [[ "${last_stakedist_block}" == "" ]] || [[ "${last_stakedist_block}" == "[]" ]] || [[ $(( block_no - last_stakedist_block )) -gt 2000 ]]; then
    log_err "Stake Distribution cache too far from tip !!"
    optexit
  fi
  if [[ "${last_poolhist_update}" == "" ]] || [[ "${last_poolhist_update}" == "[]" ]] || [[ $(( $(TZ='UTC' date +%s) - $(date -d "${last_poolhist_update}" -u +%s) )) -gt 1000 ]]; then
    log_err "Pool History cache too far from tip !!"
    optexit
  fi
  if [[ "${last_actvstake_epoch}" == "" ]] || [[ "${last_actvstake_epoch}" == "[]" ]]; then
    log_err "Active Stake cache not populated !!"
    optexit
  else
    [[ -z "${GENESIS_JSON}" ]] && GENESIS_JSON="${PARENT}"/../files/shelley-genesis.json
    epoch_length=$(jq -r .epochLength "${GENESIS_JSON}" 2>/dev/null)
    if [[ ${epoch_slot} -ge $(( epoch_length / 6 )) ]]; then
      if [[ ${last_actvstake_epoch} -lt ${epoch} ]]; then
        log_err "Active Stake cache for epoch ${epoch} still not populated as of ${epoch_slot} slot, maximum tolerance was $(( epoch_length / 6 )) !!"
        optexit
      fi
    fi
  fi
}

function chk_limit() {
  limit=$(curl -skL "${URLRPC}"/blocks -I | grep -i 'content-range' | sed -e 's#.*.-##' -e 's#/.*.##' 2>/dev/null)
  if [[ "${limit}" != "999" ]]; then
    log_err "The PostgREST config for uses a custom limit that does not match monitoring instances"
    optexit
  fi
}

function chk_endpt_get() {
  local endpt=${1}
  [[ "${2}" != "rpc" ]] && urlendpt="${GURL}/${endpt}" || urlendpt="${URLRPC}/${endpt}"
  getrslt=$(curl -sfkL "${urlendpt}" -H "Range: 0-1" 2>/dev/null)
  if [[ -z "${getrslt}" ]] || [[ "${getrslt}" == "[]" ]]; then
    log_err "Could not fetch from endpoint ${urlendpt}, response received : $(curl -skL "${urlendpt}" -H "Range: 0-1" -I) !!"
    optexit
  fi
}

function chk_endpt_post() {
  local endpt="${1}"
  local data="${2}"
  echo rslt="$(curl -skL -X POST -H "Content-Type: application/json" "${URLRPC}/${endpt}" -d "${data}" 2>&1)"
}

function chk_asset_registry() {
  ct=$(curl -sfkL -H 'Prefer: count=exact' "${URLRPC}/asset_token_registry?select=asset_name&limit=1" -I 2>/dev/null | grep -i "content-range" | cut -d/ -f2 | tr -d '[:space:]')
  if [[ "${ct}" == "" ]] || [[ $ct -lt 150 ]]; then
    log_err "Asset registry cache seems incomplete (<150) assets, try deleting key: asset_registry_commit in control_table and wait for next cron run"
    optexit
  fi
}

##################
# Main Execution #
##################

PARENT="$(dirname "${0}")"

if [[ "$3" == "-d" || "$5" == "-d" ]]; then
  export DEBUG_MODE=1
  echo "Debug Mode enabled!"
fi
if [[ $# = 2 ]] || [[ $# = 3 ]]; then
  set_defaults "$1" "$2"
elif [[ $# -gt 3 ]]; then
  set_defaults
else
  usage
fi

chk_upd
chk_version
chk_rpcs
chk_tip
chk_cache_status
chk_limit
chk_asset_registry
