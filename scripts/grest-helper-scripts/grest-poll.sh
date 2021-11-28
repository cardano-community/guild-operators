#!/usr/bin/env bash
#shellcheck disable=SC2034

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
#  - [ ] Add updateCheck for grest-poll itself, checked hourly (or at first run post haproxy restart)
#  - [ ] Add interval to download spec URL and API_COMPARE
#  - [ ] Elect few endpoints that will indirectly test data
#        - [x] Control Table (TODO: Version addition to Control Table)
#        - [ ] Query a sample from cache table (based on inputs from control table)
#        - [ ] We may not want to perform extensive dbsync data scan itself, except if bug/troublesome data on dbsync (eg: stake not being populated ~10 hours into epoch)
#  - [ ] If required and entire polling takes more than 3 seconds, Randomise some of the checks between the elected endpoints
#  - [ ] Add -d flag for debug mode - to run all tests without quitting
#

#TIP_DIFF=600                                                  # Maximum tolerance in seconds for tip to be apart before marking instance as not available to serve requests
#APIPATH=rpc                                                   # Default API path (without start/end slashes) to serve URL endpoints
#API_COMPARE="http://127.0.0.1:8050"                           # Source to be used for comparing RPC endpoint structure against. This variable only impacts failover "locally".
                                                               # Any changes here does not impact your nodes availability remotely, preventing loop of connections within proxies
#API_STRUCT_DEFINITION="https://api.koios.rest/koiosapi.yaml"  # The Doc URL that is to be considered as source of truth - only to be changed if not working with alpha branch

######################################
# Do NOT modify code below           #
######################################

function set_defaults() {
  [[ -z "${TIP_DIFF}" ]] && TIP_DIFF=600
  [[ -z "${APIPATH}" ]] && APIPATH=rpc
  [[ -z "${API_COMPARE}" ]] && API_COMPARE="http://127.0.0.1:8050"
  [[ -z "${API_STRUCT_DEFINITION}" ]] && API_STRUCT_DEFINITION="https://api.koios.rest/koiosapi.yaml"
  [[ "${HAPROXY_SERVER_NAME}" == *ssl ]] && SCHEME="https" || SCHEME="http"
  URL="${SCHEME}://${1}:${2}"
  URLRPC="${URL}/${APIPATH}"
}

function usage() {
  echo -e "\nUsage: $(basename "$0") <haproxy IP> <haproxy port> <server IP> <server port> [-d]\n"
  echo -e "Polling script used by haproxy to query server IP at server Port, and perform health checks. Use -d to run all health checks each time.\n\n"
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
    echo "ERROR: ${URLRPC}/tip endpoint did not provide a timestamp that's within ${TIP_DIFF} seconds"
    echo "       Tip: ${currtip}, DB Tip: ${dbtip}, Difference: $(( $(date -d "${currtip}" +%s) - $(date -d "${dbtip}" +%s) ))"
    exit 1
  else
    epoch=${tip[0]}
    abs_slot=${tip[1]}
    epoch_slot=${tip[2]}
    block_no=${tip[3]}
  fi
}

function chk_rpc_struct() {
  srvr_spec="$(curl -skL "${1}" | jq 'leaf_paths | join(".")' 2>/dev/null)"
  api_endpts="$(curl -skL "${API_STRUCT_DEFINITION}" | grep ^\ \ / | sed -e 's#  /#/#g' -e 's#:##' | sort)"
  for endpt in ${api_endpts}
  do
    echo "${srvr_spec}" | grep -e "paths.*.${endpt}\\."
  done
}

function chk_rpcs() {
  instance_rpc_cksum="$(chk_rpc_struct "${URL}" | sort | shasum -a 256)"
  monitor_rpc_cksum="$(chk_rpc_struct "${API_COMPARE}" | sort | shasum -a 256)"
  if [[ "${instance_rpc_cksum}" != "${monitor_rpc_cksum}" ]]; then
    echo "ERROR: The specs returned by ${URL} do not seem to match ${API_COMPARE} for endpoints mentioned at:"
    echo "  ${API_STRUCT_DEFINITION}"
    exit 1
  fi
}

function chk_cache_status() {
  last_stakedist_block=$(curl -skL "${URL}/control_table?key=eq.stake_distribution_lbh" | jq -r .[0].last_value 2>/dev/null)
  last_poolhist_update=$(curl -skL "${URL}/control_table?key=eq.pool_history_cache_last_updated" | jq -r .[0].last_value 2>/dev/null)
  if [[ "${last_stakedist_block}" == "" ]] || [[ $(( block_no - last_stakedist_block )) -gt 1000 ]]; then
    echo "ERROR: Stake Distribution cache too far from tip !!"
    exit 1
  fi
  if [[ $(( $(TZ='UTC' date +%s) - $(date -d "${last_poolhist_update}" +%s) )) -gt 1000 ]]; then
    echo "ERROR: Pool History cache too far from tip !!"
    exit 1
  fi
  # TODO: Ensure other cache tables have entry in control table , potentially with last update time
}

function chk_limit() {
  limit=$(curl -skL "${URL}"/blocks -I | grep -i 'content-range' | sed -e 's#.*.-##' -e 's#/.*.##' 2>/dev/null)
  if [[ "${limit}" != "999" ]]; then
    echo "ERROR: The PostgREST config for uses a custom limit that does not match monitoring instances"
    exit 1
  fi
}

function chk_endpt_get() {
  local endpt=${1}
  [[ "${2}" != "rpc" ]] && urlendpt="${URL}/${endpt}" || urlendpt="${URLRPC}/${endpt}"
  getrslt=$(curl -skL "${urlendpt}" -H "Range: 0-1" 2>/dev/null)
  if [[ -z "${getrslt}" ]] || [[ "${getrslt}" == "[]" ]]; then
    echo "ERROR: Could not fetch from endpoint ${urlendpt} !!"
    exit 1
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
fi

set_defaults "$3" "$4"
chk_tip
chk_rpcs
chk_cache_status
chk_limit
chk_endpt_get "genesis" view
chk_endpt_get "tx_metalabels" view
chk_endpt_get "account_list" view
chk_endpt_get "totals?_epoch_no=${epoch}" rpc
chk_endpt_get "epoch_params?_epoch_no=${epoch}" rpc
chk_endpt_get "pool_list" rpc
