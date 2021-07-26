#!/usr/bin/env bash
#shellcheck disable=SC2005,SC2046,SC2154,SC2155,SC2034,SC2086
#shellcheck source=/dev/null

. "$(dirname $0)"/env offline

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

RESTAPI_PORT=8050             # PostgREST port
HAPROXY_PORT=8053             # HAProxy port

######################################
# Do NOT modify code below           #
######################################

. "$(dirname $0)"/env
exec 2>/dev/null

function get-metrics() {
  shopt -s expand_aliases
  if [ -n "$SERVED" ]; then
    echo "Content-type: text/plain" # Tells the browser what kind of content to expect
    echo "" # request body starts from this empty line
  fi
  # Replace the value for URL as appropriate
  RESTAPI_PORT=8050
  # Stats data
  currtip=$(TZ='UTC' date "+%Y-%m-%d %H:%M:%S")
  getNodeMetrics
  currslottip=$(getSlotTipRef)
  dbsyncProm=$(curl -s http://127.0.0.1:8080 | grep ^cardano)
  meminf=$(grep "^[MSBC][ewua][mafc]" /proc/meminfo)
  load1m=$(( $(awk '{ print $1*100 }' /proc/loadavg) / $(grep -c ^processor /proc/cpuinfo) ))
  memtotal=$(( $(echo "${meminf}" | grep MemTotal | awk '{print $2}') + $(echo "${meminf}" | grep SwapTotal | awk '{print $2}') ))
  memused=$(( memtotal - $(echo "${meminf}" | grep MemFree | awk '{print $2}') - $(echo "${meminf}" | grep SwapFree | awk '{print $2}') - $(echo "${meminf}" | grep ^Buffers | awk '{print $2}') - $(echo "${meminf}" | grep ^Cached | awk '{print $2}') ))
  cpuutil=$(awk -v a="$(awk '/cpu /{print $2+$4,$2+$4+$5}' /proc/stat; sleep 1)" '/cpu /{split(a,b," "); print 100*($2+$4-b[1])/($2+$4+$5-b[2])}'  /proc/stat)

  # Metrics
  [[ -n "${dbsyncProm}" ]] && export METRIC_dbsynctipref=$(( currslottip - $(printf %f "$(echo "${dbsyncProm}" | grep cardano_db_sync_db_slot_height | awk '{print $2}')" |cut -d. -f1) ))
  export METRIC_nodetipref=$(( currslottip - slotnum ))
  export METRIC_uptime="${uptimes}"
  export METRIC_dbsyncBlockHeight=$(echo "${dbsyncProm}" | grep cardano_db_sync_db_block_height | awk '{print $2}' | cut -d. -f1)
  export METRIC_nodeBlockHeight=${blocknum}
  export METRIC_dbsyncQueueLength=$(echo "${dbsyncProm}" | grep cardano_db_sync_db_queue_length | awk '{print $2}' | cut -d. -f1)
  export METRIC_memtotal="${memtotal}"
  export METRIC_memused="${memused}"
  export METRIC_cpuutil="${cpuutil}"
  export METRIC_load1m="$(( load1m ))"
  #export METRIC_cnodeversion="$(echo $(cardano-node --version) | awk '{print $2 "-" $9}')"
  #export METRIC_dbsyncversion="$(echo $(cardano-db-sync-extended --version) | awk '{print $2 "-" $9}')"
  #export METRIC_psqlversion="$(echo "" | psql cexplorer -c "SELECT version();" | grep PostgreSQL | awk '{print $2}')"

  for metric_var_name in $(env | grep ^METRIC | sort | awk -F= '{print $1}')
  do
    METRIC_NAME=${metric_var_name//METRIC_/}
    # default NULL values to 0
    if [ -z "${!metric_var_name}" ]
    then
      METRIC_VALUE="0"
    else
      METRIC_VALUE="${!metric_var_name}"
    fi
    echo "${METRIC_NAME} ${METRIC_VALUE}"
  done
}

get-metrics
