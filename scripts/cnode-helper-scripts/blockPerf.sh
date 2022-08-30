#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086,SC2281

# Script to collect block information across nodes to provide comprehensive analytics data from participants
# For now, the script is intended for mainnet network only.

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#CONFIG=""             # Outside the cnTools environment you can manually point this script to your nodes config.json file
#SELFISH_MODE='Y'      # in case you don't want to share this node's block propagation data, turn the selfish mode on (Y)
#SERVICE_MODE='N'      # if you deploy-as-service this script it will run with the -s (service) parameter, and surpress console/syslog output. you can overwrite it here, restart the service and watch the console output with 'journalctl -f -u cnode-tu-blockperf'

#AddrBlacklist="192.168.1.123, " # uncomment with your block producers or other nodes IP that you do not want to expose to common view

######################################
# Do NOT modify code below           #
######################################

BP_VERSION=v1.2.1

deploy_systemd() {
  echo "Deploying ${CNODE_VNAME} blockPerf as systemd service.."
  sudo bash -c "cat << 'EOF' > /etc/systemd/system/${CNODE_VNAME}-tu-blockperf.service
[Unit]
Description=Cardano Node - Block Performance
BindsTo=${CNODE_VNAME}.service
After=${CNODE_VNAME}.service

[Service]
Type=simple
Restart=on-failure
RestartSec=20
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/blockPerf.sh -s\"
KillSignal=SIGINT
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${CNODE_VNAME}-tu-blockperf
TimeoutStopSec=5
KillMode=mixed
ExecStop=rm -f -- '${CNODE_HOME}/blockPerf-running.pid'

[Install]
WantedBy=${CNODE_VNAME}.service
EOF" && echo "${CNODE_VNAME}-tu-blockperf.service deployed successfully!!" && sudo systemctl daemon-reload && sudo systemctl enable ${CNODE_VNAME}-tu-blockperf.service
}

usage() {
  cat <<-EOF
		
		Usage: $(basename "$0") [-d] [-s]
		
		Cardano Node wrapper script !!
		-d    Deploy cnode-tu-blockperf as a systemd service
		-s    Run cnode-tu-blockperf without INFO message output to console/syslog 
		
		EOF
  exit 1
}
###################
# Execution       #
###################

# Parse command line options
while getopts :ds opt; do
  case ${opt} in
    d ) DEPLOY_SYSTEMD="Y" ;;
    s ) if [[ -z $SERVICE_MODE ]]; then SERVICE_MODE="Y"; fi ;;
    \? ) usage ;;
  esac
done

if [ -z "$CONFIG" ]; then
  # in CNTools environments just let the script determine config, logfile, parameters
  [[ -f "$(dirname $0)"/env ]] &&  . "$(dirname $0)"/env offline
else 
  # parse the min required values from the specified CONFIG file  
  if ! GENESIS_JSON=$(jq -er '.ShelleyGenesisFile' "${CONFIG}" 2>/dev/null); then
    echo "ERROR: Could not get 'ShelleyGenesisFile' in ${CONFIG}" && exit 1
  else
    # if relative path is used, assume same parent dir as config
    [[ ! ${GENESIS_JSON} =~ ^/ ]] && GENESIS_JSON="$(dirname "${CONFIG}")/${GENESIS_JSON}"
    [[ ! -f "${GENESIS_JSON}" ]] && echo "ERROR: Shelley genesis file not found: ${GENESIS_JSON}" && exit 1
  fi
fi

#Deploy systemd if -d argument was specified
if [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  deploy_systemd && exit 0
  exit 2
fi

unset logfile
if [[ "${CONFIG##*.}" = "json" ]] && [[ -f ${CONFIG} ]]; then
  errors=0
  logfile=$(jq -r '.setupScribes[] | select (.scFormat == "ScJson") | .scName' "${CONFIG}")
  [[ -z "${logfile}" ]] && echo -e "${RED}Error:${NC} Failed to locate json logfile in node configuration file\na setupScribe of format ScJson with extension .json expected" && errors=1
  [[ -z ${EKG_HOST} ]] && EKG_HOST=127.0.0.1
  [[ -z ${EKG_PORT} ]] && EKG_PORT=$(jq .hasEKG $CONFIG)
  [[ -z "${EKG_PORT}" ]] && echo -e "ERROR: Failed to locate the EKG Port in node configuration file" && errors=1
  NWMAGIC=$(jq -r .networkMagic < ${GENESIS_JSON})
  [[ "$(jq -r .TraceChainSyncClient "${CONFIG}")" != "true" ]] && echo "ERROR: In config file please set \"TraceChainSyncClient\":\"true\"" && errors=1
  [[ "$(jq -r .TraceBlockFetchClient "${CONFIG}")" != "true" ]] && echo "ERROR: In config file please set \"TraceBlockFetchClient\":\"true\"" && errors=1
  [[ $errors -eq 1 ]] && exit 1
else 
  echo "ERROR: Failed to locate json configuration file" && exit 1
fi

# simple-static way to convert slotnumber <=> unixtime (works as slong as slot time is 1sec)
case ${NWMAGIC} in  
  1) 
    [[ -z ${NETWORK_NAME} ]] && NETWORK_NAME="PreView"
    NETWORK_UTIME_OFFSET=1660003200;;  
  2) 
    [[ -z ${NETWORK_NAME} ]] && NETWORK_NAME="PreView"
    NETWORK_UTIME_OFFSET=1655683200;;
  764824073) 
    [[ -z ${NETWORK_NAME} ]] && NETWORK_NAME="Mainnet"
    NETWORK_UTIME_OFFSET=1591566291;; 
  *)
    echo "ERROR: Currently only Mainnet, PreProd and PreView are supported" && exit 1
esac

# check if the script is not already running (service and console) 
pidfile=${CNODE_HOME}/blockPerf-${NETWORK_NAME}.pid
if [[ -f ${pidfile} ]]; then
    echo "WARN: This script is already running on this node for ${NETWORK_NAME} network (probably as a service)" && exit 1
else
	trap "rm -f -- '$pidfile'" EXIT
	echo $! > $pidfile
fi

echo "INFO parsing ${logfile} for ${NETWORK_NAME} blocks (networkmagic: ${NWMAGIC})"

# on (re)start wait until node metrics become available
while true [ -z $(curl -s -H 'Accept: application/json' http://${EKG_HOST}:${EKG_PORT}/ | jq -r '.cardano.node.metrics.blockNum.int.val //0') ]
do
    blockHeightPrev=$(curl -s -H 'Accept: application/json' http://${EKG_HOST}:${EKG_PORT}/ | jq -r '.cardano.node.metrics.blockNum.int.val //0')
    if [ -z $blockHeightPrev ] || [ $blockHeightPrev == 0 ] ; then
      echo "WARN: can't query EKG on http://${EKG_HOST}:${EKG_PORT} ... waiting ..."
      sleep 5
	else 
	  break;
    fi
done

missingTbh=true; missingCbf=true; 

getDeltaMS() {
  echo $(echo "$2 $4" | awk -F '[:, ]' '{print ($1*3600000+$2*60000+$3*1000+$4)-($5*3600000+$6*60000+$7*1000+$8) }')
}

getSlotDate() {
  echo $(date -d @$(( $1 + $NETWORK_UTIME_OFFSET )) +'%F %T')
}

while true
do
  blockHeight=$(curl -s -H 'Accept: application/json' http://${EKG_HOST}:${EKG_PORT}/ | jq -r '.cardano.node.metrics.blockNum.int.val //0' )
  if [ -z $blockHeight ] || [ "$blockHeight" -eq 0 ]; then
    echo "WARN: can't query EKG on http://${EKG_HOST}:${EKG_PORT}/ ..."
    sleep 10
  elif  [ "$blockHeight" -gt "$blockHeightPrev" ] ; then # new Block
  
    for (( iblockHeight=$blockHeightPrev+1; iblockHeight<=$blockHeight; iblockHeight++ ))
    do  #catch up from previous to current blockheight
    
      blockHash=$(grep -m 1 "$iblockHeight" ${logfile} | jq -r .data.block)
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
                [ -z "$blockSlotTime" ] && blockSlotTime=$(getSlotDate ${blockSlot})
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
                 .data.size //0,
                 .env //0
                 ] | @tsv' <<< "${blockLogLine}")
                read -ra line_data_arr <<< ${line_tsv}
                [ -z "$blockTimeCbf" ] && blockTimeCbf=$(date -d ${line_data_arr[0]} +"%F %T,%3N")
                [ -z "$blockTimeCbfAddr" ] && blockTimeCbfAddr=${line_data_arr[1]}
                [ -z "$blockTimeCbfPort" ] && blockTimeCbfPort=${line_data_arr[2]}
                [ -z "$blockDelay" ] && blockDelay=${line_data_arr[3]}
                [ -z "$blockSize" ] && blockSize=${line_data_arr[4]}
                [ -z "$BPenv" ] && envBP=${line_data_arr[5]}
                missingCbf=false
              fi
              ;;
            TraceAddBlockEvent.AddedToCurrentChain)
              [ -z "$blockTimeAb" ] && blockTimeAb=$(date -d $(jq -r .at <<< $blockLogLine) +"%F %T,%3N")
              break
              ;;
          esac;
          blockLogLineCycles=$((blockLogLineCycles+1))
          if [[ "$blockLogLineCycles" -gt 500 ]]; then 
            # security escape after max 100 loglines 
            echo "WARN: blockheight:${iblockHeight} (leave loglines loop)" 
            break
          fi
        done <<< "$blockLog"
      else
        # an empty result grep'ing for blockHash (shouldn't happen, may on log-rotation?)
        echo "WARN: blockheight:${iblockHeight} (block hash not found in logs)"
      fi
      [[ -z  ${slotHeightPrev} ]] && slotHeightPrev=${blockSlot} # first monitored block only 
      
      if [[ ! -z ${blockTimeTbh} ]]; then
        # calculate delta-milliseconds from original slottime
        deltaSlotTbh=$(getDeltaMS ${blockTimeTbh} ${blockSlotTime},000)
        deltaTbhSfr=$(( $(getDeltaMS ${blockTimeSfr} ${blockSlotTime},000) - deltaSlotTbh))
        deltaSfrCbf=$(( $(getDeltaMS ${blockTimeCbf} ${blockSlotTime},000) - deltaTbhSfr - deltaSlotTbh))
        deltaCbfAb=$(( $(getDeltaMS ${blockTimeAb} ${blockSlotTime},000) - deltaSfrCbf - deltaTbhSfr - deltaSlotTbh))
		# may blacklist some internal IPs, to not expose them to common views (api.clio.one)
		if [[ "$AddrBlacklist" == *"$blockTimeCbfAddr"* ]]; then
			blockTimeCbfAddrPublic="0.0.0.0"
			blockTimeCbfPortPublic="0"
			echo "DBG: $blockTimeCbfAddr redacted"
		else
			blockTimeCbfAddrPublic=$blockTimeCbfAddr
			blockTimeCbfPortPublic=$blockTimeCbfPort
		fi
        if [[ "$deltaSlotTbh" -lt 0 ]] ||[[ "$deltaTbhSfr" -lt 0 ]] ||[[ "$deltaSfrCbf" -lt 0 ]] ||[[ "$deltaCbfAb" -lt 0 ]]; then
          # don't report abnormal cases with negative delta time values. eg block was produced by this node. 
          echo "WARN: blockheight:${iblockHeight} (negative delta) tbh:${blockTimeTbh} ${deltaSlotTbh} sfr:${blockTimeSfr} ${deltaTbhSfr} cbf:${blockTimeCbf} ${deltaSfrCbf} ab:${blockTimeAb} ${deltaCbfAb}" 
        else
          if [[ "${deltaSlotTbh}" -lt 10000 ]] && [[ "$((blockSlot-slotHeightPrev))" -lt 200 ]]; then
            [[ ${SELFISH_MODE} != "Y" ]] && result=$(curl -4 -s "https://api.clio.one/blocklog/v1/?magic=${NWMAGIC}&bpv=${BP_VERSION}&bn=${iblockHeight}&slot=${blockSlot}&tbh=${deltaSlotTbh}&sfr=${deltaTbhSfr}&cbf=${deltaSfrCbf}&ab=${deltaCbfAb}&size=${blockSize}&addr=${blockTimeCbfAddrPublic}&port=${blockTimeCbfPortPublic}&bh=${blockHash}&bpenv=${envBP}" &)
            [[ ${SERVICE_MODE} != "Y" ]] && echo -e "${FG_YELLOW}Block:.... ${iblockHeight} (${blockHash:0:7}...)\n${NC} Slot..... ${blockSlot} (+$((blockSlot-slotHeightPrev))s)\n ......... ${blockSlotTime}\n Header... ${blockTimeTbh} (+${deltaSlotTbh} ms)\n Request.. ${blockTimeSfr} (+${deltaTbhSfr} ms)\n Block.... ${blockTimeCbf} (+${deltaSfrCbf} ms)\n Adopted.. ${blockTimeAb} (+${deltaCbfAb} ms)\n Size..... ${blockSize} bytes\n delay.... ${blockDelay} sec\n From..... ${blockTimeCbfAddr}:${blockTimeCbfPort}"
          else
            # skip block reporting while node is synching up
            [[ ${SERVICE_MODE} != "Y" ]] && echo -e "${FG_YELLOW}Block:.... ${iblockHeight} skipped\n${NC} Slot..... ${blockSlot}\n ......... ${blockSlotTime}\n now...... $(date +"%F %T")"
            sleep 10
          fi
        fi
      fi
      
      # prepare for next round
      slotHeightPrev=$blockSlot; 
      blockTimeTbh=""; missingTbh=true; blockTimeSfr=""; blockTimeCbf=""; missingCbf=true; blockTimeCbfAddr=""; blockTimeCbfPort=""; blockTimeAb=""; blockSlot=""; blockSlotTime=""
      blockDelay=""; blockSize=""; blockTimeDeltaSlots=0; deltaCbf=""; deltaSfr=""; deltaAb=""; 
    done  # catch up from previous to current blockheight
    blockHeightPrev=$blockHeight; 
  fi
  
  sleep 1 # slot and second
done
