#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086,SC2281

# Script to collect block information across nodes to provide comprehensive analytics data from participants
# For now, the script is intended for mainnet network only.

#Todo:
# - adapt for node names != cnode

# Outside the cnTools environment you can manually point this script to your nodes config.json file
CONFIG=""  # for example "/home/user/mynode/logs/node0.json"

# in case you don't want to share this node's block propagation data, turn the selfish mode on (Y)
SELFISH_MODE='N'

######################################
# Do NOT modify code below           #
######################################

if [[ $(pgrep -fl blockPerf.sh | wc -l ) -gt 2 ]]; then
    echo "WARN: This script is already running (probably as a service)" && exit 1
fi

# in CNTools environments just let the script determine config and logfile
if [ -z "$CONFIG" ]; then
  [[ -f "$(dirname $0)"/env ]] &&  . "$(dirname $0)"/env offline
fi

SERVICE_MODE='N'
[[ $1 = "service" ]] && SERVICE_MODE='Y'

unset logfile
if [[ "${CONFIG##*.}" = "json" ]] && [[ -f ${CONFIG} ]]; then
  errors=0
  logfile=$(jq -r '.setupScribes[] | select (.scFormat == "ScJson") | .scName' "${CONFIG}")
  [[ -z "${logfile}" ]] && echo -e "${RED}Error:${NC} Failed to locate json logfile in node configuration file\na setupScribe of format ScJson with extension .json expected" && errors=1
  [[ -z ${EKG_HOST} ]] && EKG_HOST=127.0.0.1
  [[ -z ${EKG_PORT} ]] && EKG_PORT=$(jq .hasEKG $CONFIG)
  [[ -z "${EKG_PORT}" ]] && echo -e "ERROR: Failed to locate the EKG Port in node configuration file" && errors=1
  [[ "$(jq -r .TraceChainSyncClient "${CONFIG}")" != "true" ]] && echo -e "ERROR: In config file please set ${FG_YELLOW}\"TraceChainSyncClient\":\"true\"${NC}" && errors=1
  [[ "$(jq -r .TraceBlockFetchClient "${CONFIG}")" != "true" ]] && echo -e "ERROR: In config file please set ${FG_YELLOW}\"TraceBlockFetchClient\":\"true\"${NC}" && errors=1
  [[ $errors -eq 1 ]] && exit 1
else 
  echo "ERROR: Failed to locate json configuration file" && exit 1
fi

[[ ${SERVICE_MODE} = "N" ]] && echo "INFO parsing ${logfile} ..." 

blockHeightPrev=0; missingTbh=true; missingCbf=true; 

getDeltaMS() {
  echo $(echo "$2 $4" | awk -F '[:, ]' '{print ($1*3600000+$2*60000+$3*1000+$4)-($5*3600000+$6*60000+$7*1000+$8) }')
}

while true
do
  blockHeight=$(curl -s -H 'Accept: application/json' http://${EKG_HOST}:${EKG_PORT}/ | jq -r '.cardano.node.metrics.blockNum.int.val //0' )
  if [ -z $blockHeight ] || [ "$blockHeight" -eq 0 ]; then
    echo "WARN: can't query EKG on http://${EKG_HOST}:${EKG_PORT}/ ..."
    sleep 10
  elif  [ "$blockHeight" -gt "$blockHeightPrev" ] ; then # new Block
  
    blockHash=$(grep -m 1 "$blockHeight" ${logfile} | jq -r .data.block)
    blockLog=$(grep ${blockHash:0:7} ${logfile})
    
    if [[ ! -z "$blockLog" ]]; then
      blockLogLineCycles=0
      while IFS= read -r blockLogLine;do
        # parse block and propagation metrics from different log kinds
        lineKind=$(jq -r .data.kind <<< $blockLogLine)
        case $lineKind in
          ChainSyncClientEvent.TraceDownloadedHeader)
            if $missingTbh; then
              line_tsv=$(jq -r '[
               .at //0,
               .data.slot //0
               ] | @tsv' <<< "${blockLogLine}")
              read -ra line_data_arr <<< ${line_tsv}
              [ -z "$blockTimeTbh" ] && blockTimeTbh=$(date -d ${line_data_arr[0]} +"%F %T,%3N")
              [ -z "$blockSlot" ] && blockSlot=${line_data_arr[1]}
              [ -z "$blockSlotTime" ] && blockSlotTime=$(getDateFromSlot ${blockSlot} '%(%F %T)T')
              missingTbh=false
            fi
            ;;
          SendFetchRequest)
            [ -z "$blockTimeSfr" ] && blockTimeSfr=$(date -d $(jq -r .at <<< $blockLogLine) +"%F %T,%3N")
            ;;
          CompletedBlockFetch)
            if $missingCbf; then
              line_tsv=$(jq -r '[
               .at //0,
               .data.peer.remote.addr //0,
               .data.peer.remote.port //0,
               .data.delay //0,
               .data.size //0
               ] | @tsv' <<< "${blockLogLine}")
              read -ra line_data_arr <<< ${line_tsv}
              [ -z "$blockTimeCbf" ] && blockTimeCbf=$(date -d ${line_data_arr[0]} +"%F %T,%3N")
              [ -z "$blockTimeCbfAddr" ] && blockTimeCbfAddr=${line_data_arr[1]}
              [ -z "$blockTimeCbfPort" ] && blockTimeCbfPort=${line_data_arr[2]}
              [ -z "$blockDelay" ] && blockDelay=${line_data_arr[3]}
              [ -z "$blockSize" ] && blockSize=${line_data_arr[4]}
              missingCbf=false
            fi
            ;;
          TraceAddBlockEvent.AddedToCurrentChain)
            [ -z "$blockTimeAb" ] && blockTimeAb=$(date -d $(jq -r .at <<< $blockLogLine) +"%F %T,%3N")
            break
            ;;
        esac;
        blockLogLineCycles=$((blockLogLineCycles+1))
        if [[ "$blockLogLineCycles" -gt 100 ]]; then 
          # security escape after max 100 loglines 
          echo "WARN: blockheight:${blockHeight} (leave loglines loop)" 
          break
        fi
      done <<< "$blockLog"
    else
      # an empty result grep'ing for blockHash (shouldn't happen, may on log-rotation?)
      echo "WARN: blockheight:${blockHeight} (block hash not found in logs)"
    fi
    [[ -z  ${slotHeightPrev} ]] && slotHeightPrev=${blockSlot} # first monitored block only 
    
    if [[ ! -z ${blockTimeTbh} ]]; then
      # calculate delta-milliseconds from original slottime
      deltaSlotTbh=$(getDeltaMS ${blockTimeTbh} ${blockSlotTime},000)
      deltaTbhSfr=$(( $(getDeltaMS ${blockTimeSfr} ${blockSlotTime},000) - deltaSlotTbh))
      deltaSfrCbf=$(( $(getDeltaMS ${blockTimeCbf} ${blockSlotTime},000) - deltaTbhSfr - deltaSlotTbh))
      deltaCbfAb=$(( $(getDeltaMS ${blockTimeAb} ${blockSlotTime},000) - deltaSfrCbf - deltaTbhSfr - deltaSlotTbh))
      if [[ "$deltaSlotTbh" -lt 0 ]] ||[[ "$deltaTbhSfr" -lt 0 ]] ||[[ "$deltaSfrCbf" -lt 0 ]] ||[[ "$deltaCbfAb" -lt 0 ]]; then
	    # don't report abnormal cases with negative delta time values. eg block was produced by this node. 
        echo "WARN: blockheight:${blockHeight} (negative delta) tbh:${blockTimeTbh} ${deltaSlotTbh} sfr:${blockTimeSfr} ${deltaTbhSfr} cbf:${blockTimeCbf} ${deltaSfrCbf} ab:${blockTimeAb} ${deltaCbfAb}" 
	  else
        if [[ "${deltaSlotTbh}" -lt 10000 ]] && [[ "$((blockSlot-slotHeightPrev))" -lt 200 ]] && [[ "${blockHeightPrev}" -gt 0 ]]; then
          [[ ${SELFISH_MODE} = "N" ]] && result=$(curl -4 -s "https://api.clio.one/blocklog/v1/?ts=$(date +"%T.%4N")&bn=${blockHeight}&slot=${blockSlot}&slott=${blockSlotTime}&tbh=${deltaSlotTbh}&sfr=${deltaTbhSfr}&cbf=${deltaSfrCbf}&ab=${deltaCbfAb}&size=${blockSize}&addr=${blockTimeCbfAddr}&port=${blockTimeCbfPort}" &)
          [[ ${SERVICE_MODE} = "N" ]] && echo -e "${FG_YELLOW}Block:.... ${blockHeight}\n${NC} Slot..... ${blockSlot} (+$((blockSlot-slotHeightPrev))s)\n ......... ${blockSlotTime}\n Header... ${blockTimeTbh} (+${deltaSlotTbh} ms)\n Request.. ${blockTimeSfr} (+${deltaTbhSfr} ms)\n Block.... ${blockTimeCbf} (+${deltaSfrCbf} ms)\n Adopted.. ${blockTimeAb} (+${deltaCbfAb} ms)\n Size..... ${blockSize} bytes\n delay.... ${blockDelay} sec\n From..... ${blockTimeCbfAddr}:${blockTimeCbfPort}"
        else
          # skip block reporting while node is synching up, and when blockLog script just started
          [[ ${SERVICE_MODE} = "N" ]] && echo -e "${FG_YELLOW}Block:.... ${blockHeight} skipped\n${NC} Slot..... ${blockSlot}\n ......... ${blockSlotTime}\n now...... $(date +"%F %T")"
          sleep 10
        fi
      fi
    fi
    
    # prepare for next round
    blockHeightPrev=$blockHeight; slotHeightPrev=$blockSlot; 
    blockTimeTbh=""; missingTbh=true; blockTimeSfr=""; blockTimeCbf=""; missingCbf=true; blockTimeCbfAddr=""; blockTimeCbfPort=""; blockTimeAb=""; blockSlot=""; blockSlotTime=""
    blockDelay=""; blockSize=""; blockTimeDeltaSlots=0; deltaCbf=""; deltaSfr=""; deltaAb=""; 
  fi
  
  sleep 1 # slot and second
done

