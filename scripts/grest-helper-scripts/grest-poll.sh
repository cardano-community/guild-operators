#!/usr/bin/env bash
#shellcheck disable=SC2034,SC1090

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#
# Todo:
#  - [x] Move check tip to function
#  - [x] Add handling of ssl to SCHEME if haproxy.cfg defines endpoint with name
#  - [x] Move hard coded values to environment variables that can be overridden
#  - [x] Add chk_endpt_get (parameters: [endpoint starting from /] [rpc|view]
#  - [x] Add chk_endpt_post (parameters: [endpoint starting from /] [data to submit to POST request]
#  - [x] Add comparisons for RPC structure itself (prefer local, as it only impacts failover 'from' local instance, and allows to test different branches
#        This comparison is purely for RPC function name, number of parameters, and name of parameters - derived from koiosapi.yaml on github
#  - [x] (External) Automate sync of koiosapi from alpha branch every 3 hours on monitoring instance
#  - [x] Remove loopback of failover (you do not want to mark yourself available, doing failover to remote instance if local struct does not match - redundant hop)
#        For previous iteration, if instance is DOWN but one of the peer is UP, haproxy would continue to mark instance as available making 2 additional hops within haproxy loop
#        The behaviour is logged on monitoring instance - so can be easily caught if abused, but more often than not would be done unintentionally
#  - [x] Ensure the postgREST limit returned is 1000
#  - [x] Add updateCheck for grest-poll itself, checked hourly (or at first run post haproxy restart)
#  - [x] Add interval to download spec URL and API_COMPARE
#  - [x] Update koios API specs to remove rpc references, this automatically also means grest-poll.sh shouldnt use RPC for comparisons (in check structure and shasum match)
#    - [x] Remove rpc ref from koiosapi.yaml, possibly use comment to identify #RPC
#    - [x] Update OpenSpec comparison (currently filters RPC for paths, that should use a seperate identifier)
#    - [x] Update API_STRUCT_DEFINITION, as it uses /rpc to create grestrpcs file
#    - [x] Verify haproxy.conf side changes
#  - [ ] Elect few endpoints that will indirectly test data
#        - [x] Control Table (TODO: Version addition to Control Table)
#        - [ ] Query a sample from cache table (based on inputs from control table)
#        - [ ] We may not want to perform extensive dbsync data scan itself, except if bug/troublesome data on dbsync (eg: stake not being populated ~10 hours into epoch)
#  - [ ] If required and entire polling takes more than 3 seconds, Randomise some of the checks between the elected endpoints
#  - [x] Add '-d' flag for debug mode - to run all tests without quitting
#

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
  [[ "${HAPROXY_SERVER_NAME}" == *ssl ]] && SCHEME="https" || SCHEME="http"
  URL="${SCHEME}://${1}:${2}"
  URLRPC="${URL}/${APIPATH}"
}

function chk_upd() {
  # Check if the update was polled within past hour
  curr_hour=$(date +%H)
  if [[ ! -f ./.last_grest_poll ]]; then
    echo "${curr_hour}" > .last_grest_poll
    curl -sfkL "${API_STRUCT_DEFINITION}" -o "${LOCAL_SPEC}" 2>/dev/null
  else
    last_hour=$(cat .last_grest_poll)
    [[ "${curr_hour}" == "${last_hour}" ]] && SKIP_UPDATE=Y || echo "${curr_hour}" > .last_grest_poll
  fi
  if [[ ! -f "${PARENT}"/env ]]; then
    echo -e "\nCommon env file missing: ${PARENT}/env"
    echo -e "This is a mandatory prerequisite, please install with prereqs.sh or manually download from GitHub\n"
    exit 1
  fi

  . "${PARENT}"/env offline &>/dev/null
  { [[ "${UPDATE_CHECK}" != "Y" ]] || [[ "${SKIP_UPDATE}" == "Y" ]] ; } && return 0
  if [[ ! $(command -v checkUpdate) ]]; then
    echo -e "\nCould not find checkUpdate function in env, make sure you're using official guild docos for installation!"
    exit 1
  fi
  #! checkUpdate env Y N N && exit 1
  ( ! checkUpdate grest-poll.sh Y N N grest-helper-scripts ) && echo "ERROR: checkUpdate Failed" && exit 1
  curl -sfkL "${API_STRUCT_DEFINITION}" -o "${LOCAL_SPEC}" 2>/dev/null || return 0
  grep " #RPC" "${LOCAL_SPEC}" | sed -e 's#^  /#/#' | cut -d: -f1 | sort > "${PARENT}/../grestrpcs"
}

function optexit() {
  [[ "${DEBUG_MODE}" != "1" ]] && exit 1
}

function usage() {
  echo -e "\nUsage: $(basename "$0") <haproxy IP> <haproxy port> <server IP> <server port> [-d]\n"
  echo -e "Polling script used by haproxy to query server IP at server Port, and perform health checks. Use '-d' parameter to run all health checks.\n\n"
  exit 1
}

function chk_tip() {
  read -ra tip <<< "$(curl -skL "${URLRPC}/tip" 2>/dev/null | jq -r '[
    .[0].epoch // 0,
    .[0].abs_slot //0,
    .[0].epoch_slot //0,
    .[0].block_no //0,
    .[0].block_time // 0
  ] | @tsv' )"
  currtip=$(TZ='UTC' date "+%Y-%m-%d %H:%M:%S")
  dbtip=${tip[4]}
  if [[ -z "${dbtip}" ]] || [[ $(( $(date -d "${currtip}" +%s) - $(date -d "${dbtip}" +%s) )) -gt ${TIP_DIFF} ]] ; then
    echo "ERROR: ${URLRPC}/tip endpoint did not provide a timestamp that's within ${TIP_DIFF} seconds - Tip: ${currtip}, DB Tip: ${dbtip}, Difference: $(( $(date -d "${currtip}" +%s) - $(date -d "${dbtip}" +%s) ))"
    optexit
  else
    epoch=${tip[0]}
    abs_slot=${tip[1]}
    epoch_slot=${tip[2]}
    block_no=${tip[3]}
  fi
}

function chk_rpc_struct() {
  srvr_spec="$(curl -skL "${1}" | jq 'leaf_paths | join(".")' 2>/dev/null)"
  api_endpts="$(grep ^\ \ / "${LOCAL_SPEC}" | sed -e 's#  /#/#g' -e 's#:##' | sort)"
  for endpt in ${api_endpts}
  do
    echo "${srvr_spec}" | grep -e "paths.*.${endpt}\\."
  done
}

function chk_rpcs() {
  instance_rpc_cksum="$(chk_rpc_struct "${URL}" | sort | grep -v -e description\"\$ -e summary\"\$ | tee .dltarget | shasum -a 256)"
  monitor_rpc_cksum="$(chk_rpc_struct "${API_COMPARE}" | sort | grep -v -e description\"\$ -e summary\"\$ | tee .dlsource | shasum -a 256)"
  if [[ "${instance_rpc_cksum}" != "${monitor_rpc_cksum}" ]]; then
    echo "ERROR: The specs returned by ${URL} do not seem to match ${API_COMPARE} for endpoints mentioned at: ${API_STRUCT_DEFINITION}"
    optexit
  fi
}

function chk_cache_status() {
  last_stakedist_block=$(curl -skL "${URL}/control_table?key=eq.stake_distribution_lbh" | jq -r .[0].last_value 2>/dev/null)
  last_poolhist_update=$(curl -skL "${URL}/control_table?key=eq.pool_history_cache_last_updated" | jq -r .[0].last_value 2>/dev/null)
  last_actvstake_epoch=$(curl -skL "${URL}/control_table?key=eq.last_active_stake_validated_epoch" | jq -r .[0].last_value 2>/dev/null)
  if [[ "${last_stakedist_block}" == "" ]] || [[ "${last_stakedist_block}" == "[]" ]] || [[ $(( block_no - last_stakedist_block )) -gt 1000 ]]; then
    echo "ERROR: Stake Distribution cache too far from tip !!"
    optexit
  fi
  if [[ "${last_poolhist_update}" == "" ]] || [[ "${last_poolhist_update}" == "[]" ]] || [[ $(( $(TZ='UTC' date +%s) - $(date -d "${last_poolhist_update}" -u +%s) )) -gt 1000 ]]; then
    echo "ERROR: Pool History cache too far from tip !!"
    optexit
  fi
  if [[ "${last_actvstake_epoch}" == "" ]] || [[ "${last_actvstake_epoch}" == "[]" ]] || [[ "${last_actvstake_epoch}" != "${epoch}" ]]; then
    echo "ERROR: Active Stake cache too far from tip !!"
    optexit
  fi
  # TODO: Ensure other cache tables have entry in control table , potentially with last update time
}

function chk_limit() {
  limit=$(curl -skL "${URL}"/blocks -I | grep -i 'content-range' | sed -e 's#.*.-##' -e 's#/.*.##' 2>/dev/null)
  if [[ "${limit}" != "999" ]]; then
    echo "ERROR: The PostgREST config for uses a custom limit that does not match monitoring instances"
    optexit
  fi
}

function chk_endpt_get() {
  local endpt=${1}
  [[ "${2}" != "rpc" ]] && urlendpt="${URL}/${endpt}" || urlendpt="${URLRPC}/${endpt}"
  getrslt=$(curl -sfkL "${urlendpt}" -H "Range: 0-1" 2>/dev/null)
  if [[ -z "${getrslt}" ]] || [[ "${getrslt}" == "[]" ]]; then
    [[ "${DEBUG_MODE}" == "1" ]] && echo "Response received for ${urlendpt} : $(curl -skL "${urlendpt}" -H "Range: 0-1" -I)"
    echo "ERROR: Could not fetch from endpoint ${urlendpt} !!"
    optexit
  fi
}

function chk_endpt_post() {
  local endpt="${1}"
  local data="${2}"
  echo rslt="$(curl -sL -X POST -H "Content-Type: application/json" "${URL}/${endpt}" -d "${data}" 2>&1)"
}

##################
# Main Execution #
##################

if [[ $# -lt 4 ]]; then
  usage
elif [[ "$5" == "-d" ]]; then
  export DEBUG_MODE=1
  echo "Debug Mode enabled!"
fi
PARENT="$(dirname "${0}")"

set_defaults "$3" "$4"
chk_upd

chk_tip
chk_rpcs
chk_cache_status
chk_limit
chk_endpt_get "genesis" view
chk_endpt_get "tx_metalabels" view
chk_endpt_get "account_list" view
chk_endpt_get "totals?_epoch_no=${epoch}" rpc
chk_endpt_get "epoch_params?_epoch_no=${epoch}" rpc
chk_endpt_get "epoch_info?_epoch_no=${epoch}" rpc
chk_endpt_get "pool_list" rpc
