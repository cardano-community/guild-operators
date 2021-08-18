#!/usr/bin/env bash


######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#RESTAPI_PORT=8050             # Destination PostgREST port
#HAPROXY_PORT=8053             # Destination HAProxy port
#DBSYNC_PROM_HOST=127.0.0.1    # Destination DBSync Prometheus Host
#DBSYNC_PROM_PORT=8080         # Destination DBSync Prometheus port
EKG_HOST=cardano-node
EKG_PORT=12788

######################################
# Do NOT modify code below           #
######################################

# Description : Query cardano-node for current metrics
getNodeMetrics() {
    node_metrics=$(curl -s -m 2 -H 'Accept: application/json' "http://${EKG_HOST}:${EKG_PORT}/" 2>/dev/null)
    node_metrics_tsv=$(jq -r '[
    .cardano.node.metrics.blockNum.int.val //0,
    .cardano.node.metrics.epoch.int.val //0,
    .cardano.node.metrics.slotInEpoch.int.val //0,
    .cardano.node.metrics.slotNum.int.val //0,
    .cardano.node.metrics.density.real.val //"-",
    .cardano.node.metrics.txsProcessedNum.int.val //0,
    .cardano.node.metrics.txsInMempool.int.val //0,
    .cardano.node.metrics.mempoolBytes.int.val //0,
    .cardano.node.metrics.currentKESPeriod.int.val //0,
    .cardano.node.metrics.remainingKESPeriods.int.val //0,
    .cardano.node.metrics.Forge["node-is-leader"].int.val //0,
    .cardano.node.metrics.Forge.adopted.int.val //0,
    .cardano.node.metrics.Forge["didnt-adopt"].int.val //0,
    .cardano.node.metrics.Forge["forge-about-to-lead"].int.val //0,
    .cardano.node.metrics.nodeStartTime.int.val //0
    ] | @tsv' <<< "${node_metrics}")
    read -ra node_metrics_arr <<< ${node_metrics_tsv}
    blocknum=${node_metrics_arr[0]}; epochnum=${node_metrics_arr[1]}; slot_in_epoch=${node_metrics_arr[2]}; slotnum=${node_metrics_arr[3]}
    [[ ${node_metrics_arr[4]} != '-' ]] && density=$(bc <<< "scale=3;$(printf '%3.5f' "${node_metrics_arr[4]}")*100/1") || density=0.0
    tx_processed=${node_metrics_arr[5]}; mempool_tx=${node_metrics_arr[6]}; mempool_bytes=${node_metrics_arr[7]}
    kesperiod=${node_metrics_arr[8]}; remaining_kes_periods=${node_metrics_arr[9]}
    isleader=${node_metrics_arr[10]}; adopted=${node_metrics_arr[11]}; didntadopt=${node_metrics_arr[12]}; about_to_lead=${node_metrics_arr[13]}
    nodeStartTime=${node_metrics_arr[14]};uptimes=$(( $(date +%s) - node_metrics_arr[14] ))
}

exec 2>/dev/null

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
  dbsyncProm=$(curl -s http://${DBSYNC_PROM_HOST}:${DBSYNC_PROM_PORT} | grep ^cardano)
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
