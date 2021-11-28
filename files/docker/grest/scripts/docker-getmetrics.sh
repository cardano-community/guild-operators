#!/usr/bin/env bash


######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#BYRON_EPOCH_LENGTH=2160            # 2160 for mainnet | other networks to-do
#BYRON_SLOT_LENGTH=20000            # 20000 for mainnet | other networks to-do
#BYRON_GENESIS_START_SEC=1506203091 # 1506203091 for mainnet | other networks to-do
#SHELLEY_TRANS_EPOCH=208            # 208 for mainnet | other networks to-do

#RESTAPI_PORT=8050                  # Destination PostgREST port
#HAPROXY_PORT=8053                  # Destination HAProxy port
#DBSYNC_PROM_HOST=cardano-db-sync   # Destination DBSync Prometheus Host
#DBSYNC_PROM_PORT=8080              # Destination DBSync Prometheus port

PROM_HOST=cardano-node
PROM_PORT=12798

######################################
# Do NOT modify code below           #
######################################

# Description : Query cardano-node for current metrics
getNodeMetrics() {
    node_metrics=$(curl -s "http://${PROM_HOST}:${PROM_PORT}/metrics" 2>/dev/null)
    [[ ${node_metrics} =~ cardano_node_metrics_nodeStartTime_int[[:space:]]([^[:space:]]*) ]] && { nodeStartTime=${BASH_REMATCH[1]} && uptimes=$(( $(date +%s) - BASH_REMATCH[1] )); } || uptimes=0
    [[ ${node_metrics} =~ cardano_node_metrics_blockNum_int[[:space:]]([^[:space:]]*) ]] && blocknum=${BASH_REMATCH[1]} || blocknum=0
    [[ ${node_metrics} =~ cardano_node_metrics_epoch_int[[:space:]]([^[:space:]]*) ]] && epochnum=${BASH_REMATCH[1]} || epochnum=0
    [[ ${node_metrics} =~ cardano_node_metrics_slotInEpoch_int[[:space:]]([^[:space:]]*) ]] && slot_in_epoch=${BASH_REMATCH[1]} || slot_in_epoch=0
    [[ ${node_metrics} =~ cardano_node_metrics_slotNum_int[[:space:]]([^[:space:]]*) ]] && slotnum=${BASH_REMATCH[1]} || slotnum=0
    [[ ${node_metrics} =~ cardano_node_metrics_density_real[[:space:]]([^[:space:]]*) ]] && density=$(bc <<< "scale=3;$(printf '%3.5f' "${BASH_REMATCH[1]}")*100/1") || density=0.0
    [[ ${node_metrics} =~ cardano_node_metrics_txsProcessedNum_int[[:space:]]([^[:space:]]*) ]] && tx_processed=${BASH_REMATCH[1]} || tx_processed=0
    [[ ${node_metrics} =~ cardano_node_metrics_txsInMempool_int[[:space:]]([^[:space:]]*) ]] && mempool_tx=${BASH_REMATCH[1]} || mempool_tx=0
    [[ ${node_metrics} =~ cardano_node_metrics_mempoolBytes_int[[:space:]]([^[:space:]]*) ]] && mempool_bytes=${BASH_REMATCH[1]} || mempool_bytes=0
    [[ ${node_metrics} =~ cardano_node_metrics_currentKESPeriod_int[[:space:]]([^[:space:]]*) ]] && kesperiod=${BASH_REMATCH[1]} || kesperiod=0
    [[ ${node_metrics} =~ cardano_node_metrics_remainingKESPeriods_int[[:space:]]([^[:space:]]*) ]] && remaining_kes_periods=${BASH_REMATCH[1]} || remaining_kes_periods=0
    [[ ${node_metrics} =~ cardano_node_metrics_Forge_node_is_leader_int[[:space:]]([^[:space:]]*) ]] && isleader=${BASH_REMATCH[1]} || isleader=0
    [[ ${node_metrics} =~ cardano_node_metrics_Forge_adopted_int[[:space:]]([^[:space:]]*) ]] && adopted=${BASH_REMATCH[1]} || adopted=0
    [[ ${node_metrics} =~ cardano_node_metrics_Forge_didnt_adopt_int[[:space:]]([^[:space:]]*) ]] && didntadopt=${BASH_REMATCH[1]} || didntadopt=0
    [[ ${node_metrics} =~ cardano_node_metrics_Forge_forge_about_to_lead_int[[:space:]]([^[:space:]]*) ]] && about_to_lead=${BASH_REMATCH[1]} || about_to_lead=0
    [[ ${node_metrics} =~ cardano_node_metrics_slotsMissedNum_int[[:space:]]([^[:space:]]*) ]] && missed_slots=${BASH_REMATCH[1]} || missed_slots=0
    [[ ${node_metrics} =~ cardano_node_metrics_RTS_gcLiveBytes_int[[:space:]]([^[:space:]]*) ]] && mem_live=${BASH_REMATCH[1]} || mem_live=0
    [[ ${node_metrics} =~ cardano_node_metrics_RTS_gcHeapBytes_int[[:space:]]([^[:space:]]*) ]] && mem_heap=${BASH_REMATCH[1]} || mem_heap=0
    [[ ${node_metrics} =~ cardano_node_metrics_RTS_gcMinorNum_int[[:space:]]([^[:space:]]*) ]] && gc_minor=${BASH_REMATCH[1]} || gc_minor=0
    [[ ${node_metrics} =~ cardano_node_metrics_RTS_gcMajorNum_int[[:space:]]([^[:space:]]*) ]] && gc_major=${BASH_REMATCH[1]} || gc_major=0
    [[ ${node_metrics} =~ cardano_node_metrics_forks_int[[:space:]]([^[:space:]]*) ]] && forks=${BASH_REMATCH[1]} || forks=0
    [[ ${node_metrics} =~ cardano_node_metrics_blockfetchclient_blockdelay_s[[:space:]]([^[:space:]]*) ]] && block_delay=${BASH_REMATCH[1]} || block_delay=0
    [[ ${node_metrics} =~ cardano_node_metrics_served_block_count_int[[:space:]]([^[:space:]]*) ]] && blocks_served=${BASH_REMATCH[1]} || block_served=0
    [[ ${node_metrics} =~ cardano_node_metrics_blockfetchclient_lateblocks[[:space:]]([^[:space:]]*) ]] && blocks_late=${BASH_REMATCH[1]} || blocks_late=0
    [[ ${node_metrics} =~ cardano_node_metrics_blockfetchclient_blockdelay_cdfOne[[:space:]]([^[:space:]]*) ]] && printf -v blocks_w1s "%.6f" ${BASH_REMATCH[1]} || blocks_w1s=0
    [[ ${node_metrics} =~ cardano_node_metrics_blockfetchclient_blockdelay_cdfThree[[:space:]]([^[:space:]]*) ]] && printf -v blocks_w3s "%.6f" ${BASH_REMATCH[1]} || blocks_w3s=0
    [[ ${node_metrics} =~ cardano_node_metrics_blockfetchclient_blockdelay_cdfFive[[:space:]]([^[:space:]]*) ]] && printf -v blocks_w5s "%.6f" ${BASH_REMATCH[1]} || blocks_w5s=0
    nodeStartTime=${node_metrics_arr[14]};uptimes=$(( $(date +%s) - node_metrics_arr[14] ))
}

exec 2>/dev/null

[[ -z ${RESTAPI_PORT} ]] && RESTAPI_PORT=8050
[[ -z ${HAPROXY_PORT} ]] && HAPROXY_PORT=8053
[[ -z ${DBSYNC_PROM_HOST} ]] && DBSYNC_PROM_HOST=127.0.0.1
[[ -z ${DBSYNC_PROM_PORT} ]] && DBSYNC_PROM_PORT=8080
[[ -z ${SHELLEY_TRANS_EPOCH} ]] && SHELLEY_TRANS_EPOCH=208
[[ -z ${BYRON_EPOCH_LENGTH} ]] && BYRON_EPOCH_LENGTH=2160
[[ -z ${BYRON_GENESIS_START_SEC} ]] && BYRON_GENESIS_START_SEC=1506203091
[[ -z ${BYRON_SLOT_LENGTH} ]] && BYRON_SLOT_LENGTH=20000



# Description : Get calculated slot number tip
getSlotTipRef() {
  current_time_sec=$(printf '%(%s)T\n' -1)
  [[ ${SHELLEY_TRANS_EPOCH} -eq -1 ]] && echo 0 && return
  byron_slots=$(( SHELLEY_TRANS_EPOCH * BYRON_EPOCH_LENGTH ))
  byron_end_time=$(( BYRON_GENESIS_START_SEC + ((SHELLEY_TRANS_EPOCH * BYRON_EPOCH_LENGTH * BYRON_SLOT_LENGTH) / 1000) ))
  if [[ ${current_time_sec} -lt ${byron_end_time} ]]; then # In Byron phase
    echo $(( ((current_time_sec - BYRON_GENESIS_START_SEC)*1000) / BYRON_SLOT_LENGTH ))
  else # In Shelley phase
    echo $(( byron_slots + (( current_time_sec - byron_end_time ) / SLOT_LENGTH ) ))
  fi
}


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
  load1m=$(( $(awk '{ print $1*100 }' /proc/loadavg) / $(grep -c ^processor /proc/cpuinfo) ))
  meminf=$(grep "^[MSBC][ewuah][:mafc]" /proc/meminfo)
  memtotal=$(( $(echo "${meminf}" | grep MemTotal | awk '{print $2}') + $(echo "${meminf}" | grep SwapTotal | awk '{print $2}') ))
  memused=$(( memtotal + $(echo "${meminf}" | grep Shmem: | awk '{print $2}') - $(echo "${meminf}" | grep MemFree | awk '{print $2}') - $(echo "${meminf}" | grep SwapFree | awk '{print $2}') - $(echo "${meminf}" | grep ^Buffers | awk '{print $2}') - $(echo "${meminf}" | grep ^Cached | awk '{print $2}') ))
  cpuutil=$(awk -v a="$(awk '/cpu /{print $2+$4,$2+$4+$5}' /proc/stat; sleep 1)" '/cpu /{split(a,b," "); print 100*($2+$4-b[1])/($2+$4+$5-b[2])}'  /proc/stat)
  # in Bytes
  pubschsize=$(psql -d cexplorer -U postgres -c "SELECT sum(pg_relation_size(quote_ident(schemaname) || '.' || quote_ident(tablename))::bigint) FROM pg_tables WHERE schemaname = 'public'" | awk 'FNR == 3 {print $1 $2}')
  grestschsize=$(psql -d cexplorer -U postgres -c "SELECT sum(pg_relation_size(quote_ident(schemaname) || '.' || quote_ident(tablename))::bigint) FROM pg_tables WHERE schemaname = 'grest'" | awk 'FNR == 3 {print $1 $2}')
  dbsize=$(( pubschsize + grestschsize ))

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
  export METRIC_pubschsize="${pubschsize}"
  export METRIC_grestschsize="${grestschsize}"
  export METRIC_dbsize="${dbsize}"
  #export METRIC_cnodeversion="$(echo $(cardano-node --version) | awk '{print $2 "-" $9}')"
  #export METRIC_dbsyncversion="$(echo $(cardano-db-sync-extended --version) | awk '{print $2 "-" $9}')"
  #export METRIC_psqlversion="$(echo "" | psql -U postgres -d cexplorer -c "SELECT version();" | grep PostgreSQL | awk '{print $2}')"
  
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