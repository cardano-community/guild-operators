#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086,SC2281

#Todo: adapt for node names != cnode
#Todo: fix logRotation lock

# Option A: you can manually point this script to your nodes config.json file
CONFIG=""  # for example "/home/user/mynode/logs/node0.json"

# Option B: in CNTools environments just let the script determine config and logfile
if [ -z "$CONFIG" ]; then
	. "${CNODE_HOME}"/scripts/env
fi

unset logfile
if [[ "${CONFIG##*.}" = "json" ]] && [[ -f ${CONFIG} ]]; then
	errors=0
	logfile=$(jq -r '.setupScribes[] | select (.scFormat == "ScJson") | .scName' "${CONFIG}")
	[[ -z "${logfile}" ]] && echo -e "${RED}Error:${NC} Failed to locate json logfile in node configuration file\na setupScribe of format ScJson with extension .json expected" && errors=1
	ekgport=$(cat $CONFIG | jq .hasEKG)
	[[ -z "${ekgport}" ]] && echo -e "${RED}Error:${NC} Failed to locate the EKG Port in node configuration file" && $errors=1
	[[ "$(jq -r .TraceChainSyncClient "${CONFIG}")" != "true" ]] && echo -e "${RED}Error:${NC} In config file please set ${FG_YELLOW}\"TraceChainSyncClient\":\"true\"${NC}" && errors=1
	[[ "$(jq -r .TraceBlockFetchClient "${CONFIG}")" != "true" ]] && echo -e "${RED}Error:${NC} In config file please set ${FG_YELLOW}\"TraceBlockFetchClient\":\"true\"${NC}" && errors=1
	[[ "$(jq -r .TraceChainSyncHeaderServer "${CONFIG}")" != "true" ]] && echo -e "${RED}Error:${NC} In config file please set ${FG_YELLOW}\"TraceChainSyncHeaderServer\":\"true\"${NC}" && errors=1
	[[ $errors -eq 1 ]] && exit 1
else 
	echo -e "${RED}Error:${NC} Failed to locate json configuration file" && exit 1
fi

echo "$(date) parsing ${logfile} ..." | tee ${CNODE_HOME}/logs/blockLog_debug.log

blockHeightPrev=$(curl -s -H 'Accept: application/json' http://127.0.0.1:$(cat $CONFIG | jq .hasEKG)/ | jq -r .cardano.node.metrics.blockNum.int.val)
blockTimeDeltaSlots=0

getDeltaMS() {
	echo $(echo "$2 $4" | awk -F '[:, ]' '{print ($1*3600000+$2*60000+$3*1000+$4)-($5*3600000+$6*60000+$7*1000+$8) }')
}

while true
do
	blockHeight=$(curl -s -H 'Accept: application/json' http://127.0.0.1:$(cat $CONFIG | jq .hasEKG)/ | jq -r .cardano.node.metrics.blockNum.int.val)
	blockTimeDeltaSlots=$((blockTimeDeltaSlots+1))
	#echo "$(date) CP0 deltaSlots:${blockTimeDeltaSlots}  blockheight:${blockHeight} ${blockHeightPrev}"
	if [ -z $blockHeight ] || [ "$blockHeight" == "null" ] || [ "$blockHeightPrev" == "null" ] ; then
		echo "WARN: can't query EKG on http://127.0.0.1:$(cat $CONFIG | jq .hasEKG)/ ..."
	elif  [ "$blockHeight" -gt "$blockHeightPrev" ] ; then # new Block
	
		#echo "$(date) CP1 deltaSlots:${blockTimeDeltaSlots}  blockheight:${blockHeight} ${blockHeightPrev}" | tee -a ${CNODE_HOME}/logs/blockLog_debug.log
		blockHash=$(grep -m 1 "$blockHeight" ${logfile} | jq -r .data.block)  # we parse the second last, now fully logged block
		blockLog=$(grep $blockHash ${logfile})

		if [[ ! -z "$blockLog" ]]; then
			blockLogLineCycles=0
			while IFS= read -r blockLogLine;do
				# parse block and propagation metrics from different log kinds
				lineKind=$(jq -r .data.kind <<< $blockLogLine)
				case $lineKind in
					ChainSyncClientEvent.TraceDownloadedHeader)
						[ -z "$blockTimeTbh" ] && blockTimeTbh=$(date -d $(jq -r .at <<< $blockLogLine) +"%F %T,%3N")
						[ -z "$blockSlot" ] && blockSlot=$(jq -r .data.slot <<< $blockLogLine)
						[ -z "$blockSlotTime" ] && blockSlotTime=$(getDateFromSlot ${blockSlot} '%(%F %T)T')
						;;
					SendFetchRequest)
						[ -z "$blockTimeSfr" ] && blockTimeSfr=$(date -d $(jq -r .at <<< $blockLogLine) +"%F %T,%3N")
						;;
					CompletedBlockFetch)
						[ -z "$blockTimeCbf" ] && blockTimeCbf=$(date -d $(jq -r .at <<< $blockLogLine) +"%F %T,%3N")
						[ -z "$blockTimeCbfAddr" ] && blockTimeCbfAddr=$(jq -r .data.peer.remote.addr <<< $blockLogLine)
						[ -z "$blockTimeCbfPort" ] && blockTimeCbfPort=$(jq -r .data.peer.remote.port <<< $blockLogLine)
						[ -z "$blockDelay" ] && blockDelay=$(jq -r .data.delay <<< $blockLogLine)
						[ -z "$blockSize" ] && blockSize=$(jq -r .data.size <<< $blockLogLine)
						;;
					ChainSyncServerEvent.TraceChainSyncServerReadBlocked.AddBlock)
						[ -z "$blockTimeAb" ] && blockTimeAb=$(date -d $(jq -r .at <<< $blockLogLine) +"%F %T,%3N")
						break
						;;
				esac;
				blockLogLineCycles=$((blockLogLineCycles+1))
				if [[ "$blockLogLineCycles" -gt 100 ]]; then 
					# security escape after max 100 loglines (doesn't fix logRotation)
					echo "$(date) CP3 deltaSlots:${blockTimeDeltaSlots}  blockheight:${blockHeight} ${blockHeightPrev}" | tee -a ${CNODE_HOME}/logs/blockLog_debug.log
					break
				fi
			done <<< "$blockLog"
		else
			# an empty result grep'ing for blockHash (shouldn't happen, may on log-rotation?)
			echo "$(date) CP2 deltaSlots:${blockTimeDeltaSlots}  blockheight:${blockHeight} ${blockHeightPrev}" | tee -a ${CNODE_HOME}/logs/blockLog_debug.log
		fi

		if [[ ! -z ${blockTimeTbh} ]]; then
			# calculate delta-milliseconds from original slottime
			deltaSlotTbh=$(getDeltaMS ${blockTimeTbh} ${blockSlotTime},000)
			deltaTbhSfr=$(( $(getDeltaMS ${blockTimeSfr} ${blockSlotTime},000) - deltaSlotTbh))
			deltaSfrCbf=$(( $(getDeltaMS ${blockTimeCbf} ${blockSlotTime},000) - deltaTbhSfr - deltaSlotTbh))
			deltaCbfAb=$(( $(getDeltaMS ${blockTimeAb} ${blockSlotTime},000) - deltaSfrCbf - deltaTbhSfr - deltaSlotTbh))
			
			echo -e "${FG_YELLOW}Block:.... ${blockHeightPrev}\n${NC} Slot..... ${blockSlot} (+${blockTimeDeltaSlots}s)\n ......... ${blockSlotTime}\n Header... ${blockTimeTbh} (+${deltaSlotTbh} ms)\n Request.. ${blockTimeSfr} (+${deltaTbhSfr} ms)\n Block.... ${blockTimeCbf} (+${deltaSfrCbf} ms)\n Adopted.. ${blockTimeAb} (+${deltaCbfAb} ms)\n Size..... ${blockSize} bytes\n delay.... ${blockDelay} sec\n From..... ${blockTimeCbfAddr}:${blockTimeCbfPort}"
			
			result=$(curl -4 -s "https://api.clio.one/blocklog/v1/?ts=$(date +"%T.%4N")&bn=${blockHeight}&slot=${blockSlot}&slott=${blockSlotTime}&tbh=${deltaSlotTbh}&sfr=${deltaTbhSfr}&cbf=${deltaSfrCbf}&ab=${deltaCbfAb}&size=${blockSize}&addr=${blockTimeCbfAddr}&port=${blockTimeCbfPort}" &)
		fi
		
		# prepare for next round
		blockHeightPrev=$blockHeight
		blockTimeTbh=""
		blockTimeSfr=""
		blockTimeCbf=""
		blockTimeCbfAddr=""
		blockTimeCbfPort=""
		blockTimeAb=""
		blockSlot=""
		blockSlotTime=""
		blockDelay=""
		blockSize=""
		blockTimeDeltaSlots=0
		deltaCbf=""
		deltaSfr=""
		deltaAb=""
	fi
	
	sleep 1 # slot and second
done

