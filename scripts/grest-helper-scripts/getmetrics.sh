#!/usr/bin/env bash
#shellcheck disable=SC2005,SC2046,SC2154,SC2155,SC2034,SC2086
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#RESTAPI_HOST=127.0.0.1        # Destination PostgREST host
#RESTAPI_PORT=8050             # Destination PostgREST port
#HAPROXY_PORT=8053             # Destination HAProxy port
#DBSYNC_PROM_HOST=127.0.0.1    # Destination DBSync Prometheus Host
#DBSYNC_PROM_PORT=8080         # Destination DBSync Prometheus port

######################################
# Do NOT modify code below           #
######################################

. "$(dirname $0)"/env
exec 2>/dev/null

[[ -z ${RESTAPI_HOST} ]] && RESTAPI_HOST=127.0.0.1
[[ -z ${RESTAPI_PORT} ]] && RESTAPI_PORT=8050
[[ -z ${HAPROXY_PORT} ]] && HAPROXY_PORT=8053
[[ -z ${DBSYNC_PROM_HOST} ]] && DBSYNC_PROM_HOST=127.0.0.1
[[ -z ${DBSYNC_PROM_PORT} ]] && DBSYNC_PROM_PORT=8080

function get-metrics() {
  shopt -s expand_aliases
  if [ -n "$SERVED" ]; then
    echo "Content-type: text/plain" # Tells the browser what kind of content to expect
    echo "" # request body starts from this empty line
  fi
  # Replace the value for URL as appropriate
  # Stats data
  currtip=$(TZ='UTC' date "+%Y-%m-%d %H:%M:%S")
  getNodeMetrics
  currslottip=$(getSlotTipRef)
  tip=$(curl -s http://${RESTAPI_HOST}:${RESTAPI_PORT}/rpc/tip)
  meminf=$(grep "^Mem" /proc/meminfo)
  load1m=$(( $(awk '{ print $1*100 }' /proc/loadavg) / $(grep -c ^processor /proc/cpuinfo) ))
  memtotal=$(( $(echo "${meminf}" | grep MemTotal | awk '{print $2}') ))
  memused=$(( memtotal - $(echo "${meminf}" | grep MemAvailable | awk '{print $2}') ))
  cpuutil=$(awk -v a="$(awk '/cpu /{print $2+$4,$2+$4+$5}' /proc/stat; sleep 1)" '/cpu /{split(a,b," "); print 100*($2+$4-b[1])/($2+$4+$5-b[2])}'  /proc/stat)
  # in Bytes
  pubschsize=$(psql -t --csv -d cexplorer -c "SELECT sum(pg_relation_size(quote_ident(schemaname) || '.' || quote_ident(tablename))::bigint) FROM pg_tables WHERE schemaname = 'public'" | grep "^[0-9]")
  grestschsize=$(psql -t --csv -d cexplorer -c "SELECT sum(pg_relation_size(quote_ident(schemaname) || '.' || quote_ident(tablename))::bigint) FROM pg_tables WHERE schemaname = 'grest'" | grep "^[0-9]")
  dbsize=$(( pubschsize + grestschsize ))

  # Metrics
  export METRIC_dbsynctipref=$(( currslottip - $( echo "${tip}" | jq .[0].abs_slot) ))
  export METRIC_nodetipref=$(( currslottip - slotnum ))
  export METRIC_uptime="${uptimes}"
  export METRIC_dbsyncBlockHeight=$(echo "${tip}" | jq .[0].block_no)
  export METRIC_nodeBlockHeight=${blocknum}
  export METRIC_dbsyncQueueLength=$(( METRIC_nodeBlockHeight - METRIC_dbsyncBlockHeight ))
  export METRIC_memtotal="${memtotal}"
  export METRIC_memused="${memused}"
  export METRIC_cpuutil="${cpuutil}"
  export METRIC_load1m="$(( load1m ))"
  export METRIC_pubschsize="${pubschsize}"
  export METRIC_grestschsize="${grestschsize}"
  export METRIC_dbsize="${dbsize}"
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
