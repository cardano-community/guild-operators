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
#BATCH_AUTO_UPDATE=N   # Set to Y to automatically update the script if a new version is available without user interaction

#CNODE_PORT=6000       # the port on which this node runs (automatically read from cnTools:env   outside cnTools you need to manually set this parameter)

#AddrBlacklist="192.168.1.123, " # uncomment with your block producers or other nodes IP that you do not want to expose to common view

######################################
# Do NOT modify code below           #
######################################

BP_VERSION=v1.3.9

SKIP_UPDATE=N
[[ $1 = "-u" ]] && SKIP_UPDATE=Y && shift

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
		-u    Skip script update check overriding UPDATE_CHECK value in env (must be first argument to script)
		-d    Deploy cnode-tu-blockperf as a systemd service
		-s    Run cnode-tu-blockperf without INFO message output to console/syslog 
		-m    Run in manual mode, by specifying a blockNum and logfile (no online reporting, just console output)
		
		EOF
  exit 1
}
###################
# Execution       #
###################

# Parse command line options
while getopts :dsm opt; do
  case ${opt} in
    d ) DEPLOY_SYSTEMD="Y" ;;
    s ) if [[ -z $SERVICE_MODE ]]; then SERVICE_MODE="Y"; fi ;;
    m ) PARSE_MANUAL="Y" ;;
    \? ) usage ;;
  esac
done

if [ -z "$CONFIG" ]; then
  # in CNTools environments just let the script determine config, logfile, parameters
  [[ -f "$(dirname $0)"/env ]] &&  . "$(dirname $0)"/env offline

  if [[ ${UPDATE_CHECK} = Y && ${SKIP_UPDATE} != Y && ${SERVICE_MODE} != Y ]]; then

    echo "Checking for script updates..."

    # Check availability of checkUpdate function
    if [[ ! $(command -v checkUpdate) ]]; then
      echo -e "\nCould not find checkUpdate function in env, make sure you're using official guild docos for installation!"
      exit 1
    fi

    # check for env update
    ENV_UPDATED=${BATCH_AUTO_UPDATE}
    checkUpdate "${PARENT}"/env N N N
    case $? in
      1) ENV_UPDATED=Y ;;
      2) exit 1 ;;
    esac

    # check for blockPerf.sh update
    checkUpdate "${PARENT}"/blockPerf.sh ${ENV_UPDATED}
    case $? in
      1) $0 "-u" "$@"; exit 0 ;; # re-launch script with same args skipping update check
      2) exit 1 ;;
    esac
  fi

  # source common env variables in case it was updated
  until . "${PARENT}"/env; do
    echo "sleeping for 10s and testing again..."
    sleep 10
  done

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

checkFixConfig() {
  # if config's key != value update config as required
  checkKey=${1}; 
  checkVal=$2;
  if [[  "$3" == "fix" ]]; then
    [[ "$(jq -r ".${checkKey}" "${CONFIG}")" != "${checkVal}" ]] && jq --argjson theKey $checkKey --argjson theVal $checkVal 'setpath($theKey; $theVal)' ${CONFIG} > ${CONFIG}.tmp && mv ${CONFIG}.tmp ${CONFIG} && echo "INFO: setting .$checkKey to ${checkVal}" && config_change=1
  else  # alert only
    [[ "$(jq -r ".${checkKey}" "${CONFIG}")" != "${checkVal}" ]] && echo "INFO: for blockPerf parsing please set ${checkKey[0]}:\"${checkVal}\" in ${CONFIG}" && config_change=1
  fi
}

#Deploy systemd if -d argument was specified
if [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  # if not already enabled activate the required Tracers in the config file
  checkFixConfig '["TraceChainSyncClient"]' true "fix";
  checkFixConfig '["TraceBlockFetchClient"]' true "fix";
  checkFixConfig '["TracingVerbosity"]' "NormalVerbosity" "fix";
  [[ $config_change -eq 1 ]] && echo "Please restart the node with new Tracers before using blockPerf."
  deploy_systemd && exit 0
  exit 2
fi

unset logfile
if [[ "${CONFIG##*.}" = "json" ]] && [[ -f ${CONFIG} ]]; then
  logfile=$(jq -r '.setupScribes[] | select (.scFormat == "ScJson") | .scName' "${CONFIG}")
  [[ -z "${logfile}" ]] && echo -e "${RED}Error:${NC} Failed to locate json logfile in node configuration file\na setupScribe of format ScJson with extension .json expected" && exit 1
  [[ -z ${EKG_HOST} ]] && EKG_HOST=127.0.0.1
  [[ -z ${EKG_PORT} ]] && EKG_PORT=$(jq .hasEKG $CONFIG)
  [[ -z "${EKG_PORT}" ]] && echo -e "ERROR: Failed to locate the EKG Port in node configuration file" && exit 1
  [[ -z "${AddrBlacklist}" ]] &&
  NWMAGIC=$(jq -r .networkMagic < ${GENESIS_JSON})
  checkFixConfig '["TraceChainSyncClient"]' true "alert";
  checkFixConfig '["TraceBlockFetchClient"]' true "alert";
  checkFixConfig '["TracingVerbosity"]' "NormalVerbosity" "alert";
  [[ $config_change -eq 1 ]] && exit 1
else 
  echo "ERROR: Failed to locate json configuration file" && exit 1
fi

# simple-static way to convert slotnumber <=> unixtime (works as slong as slot time is 1sec)
case ${NWMAGIC} in  
  1) 
    [[ -z ${NETWORK_NAME} ]] && NETWORK_NAME="PreProd"
    NETWORK_UTIME_OFFSET=1660003200;;  
  2) 
    [[ -z ${NETWORK_NAME} ]] && NETWORK_NAME="PreView"
    NETWORK_UTIME_OFFSET=1655683200;;
  141) 
    [[ -z ${NETWORK_NAME} ]] && NETWORK_NAME="Guild-Testnet"
    NETWORK_UTIME_OFFSET=1639089874;;
  764824073) 
    [[ -z ${NETWORK_NAME} ]] && NETWORK_NAME="Mainnet"
    NETWORK_UTIME_OFFSET=1591566291;; 
  *)
    echo "ERROR: Currently only Mainnet, PreProd and PreView are supported" && exit 1
esac

# check if the script is not already running (service and console) 
pidfile=${CNODE_HOME}/blockPerf-running.pid
if [[ -f ${pidfile} && "${PARSE_MANUAL}" != "Y" ]]; then
    echo "WARN: This script is already running on this node for ${NETWORK_NAME} network (probably as a service)" && exit 1
else
    trap "rm -f -- "'$pidfile'"" EXIT
    echo $! > $pidfile
fi

missingTbh=true; missingCbf=true; 

getDeltaMS() {
  echo "$(echo "$2 $4" | awk -F '[:, ]' '{print ($1*3600000+$2*60000+$3*1000+$4)-($5*3600000+$6*60000+$7*1000+$8) }' || 0)"
}

getSlotDate() {
  echo "$(date -d @$(( $1 + $NETWORK_UTIME_OFFSET )) +'%F %T')"
}

reportBlock() {
  if [[ -n "${blockLog}" ]]; then
    blockLogLineCycles=0
    while IFS= read -r blockLogLine;do
      # parse block and propagation metrics from different log kinds
      lineKind=$(jq -r .data.kind <<< $blockLogLine)
      case $lineKind in
        ChainSyncClientEvent.TraceDownloadedHeader)
          if $missingTbh; then
            line_tsv=$(jq -r '[
             .at //0,
             .data.slot //0,
             .data.peer.remote.addr //0,
             .data.peer.remote.port //0
             ] | @tsv' <<< "${blockLogLine}")
            read -ra line_data_arr <<< ${line_tsv}
            [ -z "$blockTimeTbh" ] && blockTimeTbh=$(date -d ${line_data_arr[0]} +"%F %T,%3N" || 0)
            [ -z "$blockSlot" ] && blockSlot=${line_data_arr[1]}
            [ -z "$blockTimeTbhAddr" ] && blockTimeTbhAddr=${line_data_arr[2]}
            [ -z "$blockTimeTbhPort" ] && blockTimeTbhPort=${line_data_arr[3]}
            [ -z "$blockSlotTime" ] && blockSlotTime=$(getSlotDate ${blockSlot})
            missingTbh=false
          fi
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
            [ -z "$blockTimeCbf" ] && blockTimeCbf=$(date -d ${line_data_arr[0]} +"%F %T,%3N" || 0)
            [ -z "$blockTimeCbfAddr" ] && blockTimeCbfAddr=${line_data_arr[1]}
            [ -z "$blockTimeCbfPort" ] && blockTimeCbfPort=${line_data_arr[2]}
            [ -z "$blockDelay" ] && blockDelay=${line_data_arr[3]}
            [ -z "$blockSize" ] && blockSize=${line_data_arr[4]}
            [ -z "$BPenv" ] && envBP=${line_data_arr[5]}
            missingCbf=false
            # pick the fetch request time from the effective blockk serving peer
            sbx=$(echo "${blockLog}" | grep -E -m 1 "SendFetchRequest.*${blockTimeCbfAddr}.*${blockTimeCbfPort}" | jq -r '[.at //0,.data.deltaq.G //0] | @tsv')
            read -ra line_data_arr <<< ${sbx}
            blockTimeSfrX=$(date -d ${line_data_arr[0]} +"%F %T,%3N" || 0)
            blockTimeG=${line_data_arr[1]}
            [[ -n "$blockTimeAb" ]] && break
          fi
          ;;
        TraceAddBlockEvent.AddedToCurrentChain|TraceAddBlockEvent.SwitchedToAFork)
          [ -z "$blockTimeAb" ] && blockTimeAb=$(date -d "$(jq -r .at <<< $blockLogLine)" +"%F %T,%3N" || 0)
          [ ! $missingCbf ] && break
          ;;
      esac;
      blockLogLineCycles=$((blockLogLineCycles+1))
      if [[ "$blockLogLineCycles" -gt 300 ]]; then 
        # security escape after x loglines / better safe than sorry
        echo "WARN: blockheight:${iblockHeight} (leave loglines loop)" 
        break
      fi
    done <<< "${blockLog}"
  else
    # an empty result grep'ing for blockHash (shouldn't happen, may on log-rotation?)
    echo "WARN: blockheight:${iblockHeight} (block hash not found in logs)"
  fi
  [[ -z  ${slotHeightPrev} ]] && slotHeightPrev=${blockSlot} # first monitored block only 
  if [[ -n ${blockTimeTbh} ]]; then
    # calculate delta-milliseconds from original slottime
    deltaSlotTbh=$(getDeltaMS ${blockTimeTbh} ${blockSlotTime},000)
    deltaTbhSfr=$(( $(getDeltaMS ${blockTimeSfrX} ${blockSlotTime},000) - deltaSlotTbh))
    [[ -n "$blockTimeCbf" ]] && deltaSfrCbf=$(( $(getDeltaMS ${blockTimeCbf} ${blockSlotTime},000) - deltaTbhSfr - deltaSlotTbh)) || deltaSfrCbf="NULL"
    [[ -n "$blockTimeAb" ]] && deltaCbfAb=$(( $(getDeltaMS ${blockTimeAb} ${blockSlotTime},000) - deltaSfrCbf - deltaTbhSfr - deltaSlotTbh)) || deltaCbfAb="NULL"
    [[ "$deltaCbfAb" -lt 0 ]] && deltaCbfAb=0  # rare cases of ab logged before cbf (can be removed after fixed in node )
    # may blacklist some internal IPs, to not expose them to common views (api.clio.one)
    if [[ -z "${AddrBlacklist}" ]] || [[ "$AddrBlacklist" == *"$blockTimeTbhAddr"* ]]; then
      blockTimeTbhAddrPublic="0.0.0.0"
      blockTimeTbhPortPublic="0"
    else
      blockTimeTbhAddrPublic=$blockTimeTbhAddr
      blockTimeTbhPortPublic=$blockTimeTbhPort
    fi
    if [[ -z "${AddrBlacklist}" ]] || [[ "$AddrBlacklist" == *"$blockTimeCbfAddr"* ]]; then
      blockTimeCbfAddrPublic="0.0.0.0"
      blockTimeCbfPortPublic="0"
    else
      blockTimeCbfAddrPublic=$blockTimeCbfAddr
      blockTimeCbfPortPublic=$blockTimeCbfPort
    fi
    #if [[ "$deltaSlotTbh" -lt 0 ]] ||[[ "$deltaTbhSfr" -lt 0 ]] ||[[ "$deltaSfrCbf" -lt 0 ]] ||[[ "$deltaCbfAb" -lt 0 ]]; then
    if [[ "$deltaSfrCbf" -lt 0 ]] || [[ "$deltaCbfAb" -lt 0 ]]; then
      # don't report abnormal cases with negative delta time values. eg block was produced by this node. 
      echo -e "WARN: blockheight:${iblockHeight} (negative delta) \n  tbh:${blockTimeTbh} ${deltaSlotTbh}\n  sfr:${blockTimeSfrX} ${deltaTbhSfr}\n  cbf:${blockTimeCbf} ${deltaSfrCbf}\n  ab:${blockTimeAb} ${deltaCbfAb}" 
      echo -e "DBG \n blockTimeCbfAddr: $blockTimeCbfAddr \n blockTimeCbfPort: $blockTimeCbfPort \n sbx: $sbx \n line_tsv: $line_tsv"
      #Debug: look into when and why this happens
      #echo -e "blockheight:${iblockHeight} (negative delta) \n  bhash:${blockHash}\n  tbh:${blockTimeTbh} ${deltaSlotTbh}\n  sfr:${blockTimeSfrX} ${deltaTbhSfr}\n  cbf:${blockTimeCbf} ${deltaSfrCbf}\n  ab:${blockTimeAb} ${deltaCbfAb} \n blockTimeCbfAddr: $blockTimeCbfAddr \n blockTimeCbfPort: $blockTimeCbfPort \n sbx: $sbx \n line_tsv: $line_tsv \n \n blockLogLine: \n${blockLogLine} \n\n ${blockLog}" > zzz_debug_WARN_block_${iblockHeight}.json
    else
      if [[ "${deltaSlotTbh}" -lt 60000 ]] && [[ "$((blockSlot-slotHeightPrev))" -lt 200 ]]; then
        [[ ${SELFISH_MODE} != "Y" ]] && curl -4 -s "https://api.clio.one/blocklog/v1/?magic=${NWMAGIC}&bpv=${BP_VERSION}&nport=${CNODE_PORT}&bn=${iblockHeight}&slot=${blockSlot}&tbh=${deltaSlotTbh}&tbhAddr=${blockTimeTbhAddrPublic}&tbhPort=${blockTimeTbhPortPublic}&sfr=${deltaTbhSfr}&cbf=${deltaSfrCbf}&ab=${deltaCbfAb}&g=${blockTimeG}&size=${blockSize}&addr=${blockTimeCbfAddrPublic}&port=${blockTimeCbfPortPublic}&bh=${blockHash}&bpenv=${envBP}"
        [[ ${SERVICE_MODE} != "Y" ]] && echo -e "${FG_YELLOW}Block:.... ${iblockHeight} ( ${blockHash:0:10} ...)\n${NC} Slot..... ${blockSlot} ($((blockSlot-slotHeightPrev))s)\n ......... ${blockSlotTime}\n Header... ${blockTimeTbh} (+${deltaSlotTbh} ms) from ${blockTimeTbhAddr}:${blockTimeTbhPort}\n RequestX. ${blockTimeSfrX} (+${deltaTbhSfr} ms)\n Block.... ${blockTimeCbf} (+${deltaSfrCbf} ms) from ${blockTimeCbfAddr}:${blockTimeCbfPort}\n Adopted.. ${blockTimeAb} (+${deltaCbfAb} ms)\n Size..... ${blockSize} bytes\n delay.... ${blockDelay} sec"
      else
        # skip block reporting while node is synching up
        [[ ${SERVICE_MODE} != "Y" ]] && echo -e "${FG_YELLOW}Block:.... ${iblockHeight} skipped\n${NC} Slot..... ${blockSlot}\n ......... ${blockSlotTime}\n now...... $(date +"%F %T")"
        sleep 10
      fi
    fi
  fi
  # prepare for next round
  slotHeightPrev=$blockSlot; 
  blockTimeTbh=""; missingTbh=true; blockTimeSfrX=""; blockTimeCbf=""; missingCbf=true; blockTimeCbfAddr=""; blockTimeCbfPort=""; blockTimeAb=""; blockSlot=""; blockSlotTime=""
  blockDelay=""; blockSize=""; blockTimeTbhAddr=""; blockTimeTbhPort="";
}

if [[ "${PARSE_MANUAL}" == "Y" ]]; then
  # manually parse for a certain block (no EKG tracing, no online reporting)
  echo "INFO: manual parse mode"
  if [[ $2 -gt 0  &&  -n $3 ]]; then
    SELFISH_MODE=Y # don't report this block online
    SERVICE_MODE=N # only show console output
    iblockHeight=$2
    logfile=$3
    echo " looking for block $iblockHeight"
    echo " in logfile $logfile"
    blockHash=$(grep -m 1 "$iblockHeight" ${logfile} | jq -r .data.block)
    echo "DBG Hash: $blockHash"
    blockLog=$(grep -E ${blockHash:0:10} ${logfile} | grep -E 'TraceDownloadedHeader|SendFetchRequest|CompletedBlockFetch|AddedToCurrentChain|SwitchedToAFork' )
    echo "DBG Loglines: $(echo $blockLog | grep -c ":")"
    reportBlock ${blockLog} && exit 0;
    exit 1
  else
    echo "in manual parse mode (-m) please specify [blockheight intNum] and [logfile path]"
    exit 1
  fi
fi

echo "blockPerf $BP_VERSION"
echo "parsing ${logfile} for ${NETWORK_NAME} blocks (networkmagic: ${NWMAGIC})"

# on (re)start wait until node metrics become available
while true [[ -z "$(curl -s -H 'Accept: application/json' http://${EKG_HOST}:${EKG_PORT}/ | jq -r '.cardano.node.metrics.blockNum.int.val //0')" ]]
do
    blockHeightPrev=$(curl -s -H 'Accept: application/json' http://${EKG_HOST}:${EKG_PORT}/ | jq -r '.cardano.node.metrics.blockNum.int.val //0')
    if [ -z $blockHeightPrev ] || [ $blockHeightPrev == 0 ] ; then
      echo "WARN: can't query EKG on http://${EKG_HOST}:${EKG_PORT} ... waiting ..."
      sleep 5
    else
      forksPrev=$(curl -s -H 'Accept: application/json' http://${EKG_HOST}:${EKG_PORT}/ | jq -r '.cardano.node.metrics.forks.int.val //0')
      break;
    fi
done
if [ -z $blockHeightPrev ] || [ $blockHeightPrev == 0 ] ; then
  blockHeightPrev=$(curl -s -H 'Accept: application/json' http://${EKG_HOST}:${EKG_PORT}/ | jq -r '.cardano.node.metrics.blockNum.int.val //0')
fi
if [ -z $forksPrev ] || [ $forksPrev == 0 ] ; then
  forksPrev=$(curl -s -H 'Accept: application/json' http://${EKG_HOST}:${EKG_PORT}/ | jq -r '.cardano.node.metrics.forks.int.val //0')
fi

while true
do
  line_tsv=$(jq -r '[
   .cardano.node.metrics.blockNum.int.val //0,
   .cardano.node.metrics.forks.int.val //0,
   .cardano.node.metrics.slotNum.int.val //0
   ] | @tsv' <<< "$(curl -s -H 'Accept: application/json' http://${EKG_HOST}:${EKG_PORT}/)")
  read -ra line_data_arr <<< ${line_tsv}
  blockHeight=${line_data_arr[0]}
  forks=${line_data_arr[1]}
  slotNum=${line_data_arr[2]}
  if [ -z $blockHeight ] || [ "$blockHeight" -eq 0 ]; then
    echo "WARN: can't query EKG on http://${EKG_HOST}:${EKG_PORT}/ ..."
    sleep 10
  elif [ "$blockHeight" -gt "$blockHeightPrev" ]; then # a new BlockHeight
    if [ $(( blockHeight - blockHeightPrev )) -gt 5 ] ; then # the node is (quickly) syncing up from the past: wait until synced up
      echo -e "INFO: blockheight delta from previous loop is high [$(( blockHeight - blockHeightPrev ))] Skip parsing as node seems syncing up from the past"
      blockHeightPrev=$blockHeight; 
    else
      for (( iblockHeight=$blockHeightPrev+1; iblockHeight<=$blockHeight; iblockHeight++ ))
      do  #catch up from previous to current blockheight
        blockHash=$(grep -m 1 ":$iblockHeight" ${logfile} | jq -r .data.block)
        if [[ -n $blockHash ]]; then
          blockLog=$(grep "${blockHash:0:10}" ${logfile} | grep -E 'TraceDownloadedHeader|SendFetchRequest|CompletedBlockFetch|AddedToCurrentChain|SwitchedToAFork' )
          if [[ "$(echo "${blockLog}" | grep -h -E 'TraceDownloadedHeader|SendFetchRequest|CompletedBlockFetch|AddedToCurrentChain|SwitchedToAFork' | jq -r .data.kind | sort | uniq | wc -l)" -lt 4 ]]; then 
            # grep'ed blockLog is incomplete (4 steps) probably because of log rotation. so let's grep from all logs
            blockLog=$(grep -h -E ${blockHash:0:10} ${logfile/.json/-*} ${logfile} | grep -E 'TraceDownloadedHeader|SendFetchRequest|CompletedBlockFetch|AddedToCurrentChain|SwitchedToAFork' )
          fi
          reportBlock ${blockLog};
        else
          echo -e "WARN: blockheight:${iblockHeight} no hash" 
          #Debug: look into when and why this happens
          #echo -e "blockheight:${iblockHeight} (no hash) \n\n $(grep -m 1 "$iblockHeight" ${logfile})" > zzz_debug_WARN_block_${iblockHeight}.json
        fi
        [[ ${SERVICE_MODE} != "Y" ]] && echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      done  # catch up from previous to current blockheight
      blockHeightPrev=$blockHeight; 
    fi
  elif [ "$forks" -gt "$forksPrev" ] ; then # another new Block (instead of previous one)
    blockHash=$(grep -E -m 1 "SwitchedToAFork+.*${slotNum}" ${logfile} | jq -r .data.newtip)
    blockHash=${blockHash:0:64}
    if [[ ${#blockHash} -lt 64 ]] ; then # Minimalverbosity only logs first 6chr of blockHash in SwitchedToAFork line
      blockHash=$(grep -m 1 "${blockHash}+.*$slotNum" ${logfile} | jq -r .data.block)
    fi
    if [[ -n $blockHash ]]; then
      blockLog=$(grep "${blockHash}" ${logfile} | grep -E 'TraceDownloadedHeader|SendFetchRequest|CompletedBlockFetch|AddedToCurrentChain|SwitchedToAFork')
      if [[ "$(echo "${blockLog}" | grep -h -E 'TraceDownloadedHeader|SendFetchRequest|CompletedBlockFetch|AddedToCurrentChain|SwitchedToAFork' | jq -r .data.kind | sort | uniq | wc -l)" -lt 4 ]]; then 
        # grep'ed blockLog is incomplete (4 steps) probably because of log rotation. so let's grep from all logs
        blockLog=$(grep -h -E ${blockHash:0:10} ${logfile/.json/-*} ${logfile} | grep -E 'TraceDownloadedHeader|SendFetchRequest|CompletedBlockFetch|AddedToCurrentChain|SwitchedToAFork' )
        fi
      iblockHeight=$(grep -m 1 ${blockHash} ${logfile})
      iblockHeight=$(jq -r .data.blockNo <<< "${iblockHeight}")
      #echo "b:${iblockHeight}	s:${slotNum}" >> forks.log
      reportBlock ${blockLog};
    else
      echo -e "WARN: blockheight:${iblockHeight} no hash" 
      #Debug: look into when and why this happens
      #echo -e "blockheight:${iblockHeight} (no hash) \n\n $(grep -m 1 "$iblockHeight" ${logfile})" > zzz_debug_WARN_block_${iblockHeight}.json
    fi
    [[ ${SERVICE_MODE} != "Y" ]] && echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    forksPrev=$forks; 
  fi
  sleep 1 # slot and second
  if [ "$forks" -lt "$forksPrev" ] ; then # node restarted meanwhile
    forksPrev=$forks;
  fi
done
