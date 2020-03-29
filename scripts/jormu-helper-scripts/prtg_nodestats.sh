#!/bin/bash

# Checklist:
# - If you're not sure of how to make use of this script and setup yourself to PRTG monitor, check in Private Testnet group.
# - Ensure jq is installed via Package Manager of your OS (eg: sudo yum install jq).
# - The comment on the last line "| python -m json.tool" is just present for easy human readability, and needs python to be pre-installed on the system.
# - The script uses sudo to execute netstat commands. Replace as necessary on your local system.
# - Ensure jcli is in the $PATH and accessible for the user thats running httpd/busybox.
# - You'd want to set JORMUNGANDR_RESTAPI_URL env variable beforehand (or edit the http://127.0.0.1:4100/api reference below) as seen by busybox/httpd user.

shopt -s expand_aliases
exec 2>/dev/null
echo "Content-type: application/json" # Tells the browser what kind of content to expect
echo "" # An empty line. Mandatory, if it is missed the page content will not load
# Replace the value for URL as appropriate
RESTAPI_PORT=4100
if [ ! $JORMUNGANDR_RESTAPI_URL ]; then export JORMUNGANDR_RESTAPI_URL=http://127.0.0.1:${RESTAPI_PORT}/api; fi
alias cli="$(which jcli) rest v0"

# Node stats data

if [ "$(uname -s)" == "Linux" ]; then
	lastBlockDateSlot=$(cli node stats get --output-format json | jq -r .lastBlockDate | cut -f2 -d.)
	blockRecvCnt=$(cli node stats get --output-format json | jq -r .blockRecvCnt)
	lastBlockHeight=$(cli node stats get --output-format json | jq -r .lastBlockHeight)
	uptime=$(cli node stats get --output-format json | jq -r .uptime)
	lastBlockTx=$(cli node stats get --output-format json | jq -r .lastBlockTx)
	txRecvCnt=$(cli node stats get --output-format json | jq -r .txRecvCnt)
	productionInEpoch=$(cli leaders logs get --output-format json | jq ' group_by(.scheduled_at_date | split(".")[0])[-1] |  .[]? | if .finished_at_time != null then 1 else 0 end' | awk '{sum+=$0} END{print sum}')
	tmpdt=$(cli leaders logs get | grep finished_at_ | sort | grep -v \~ | tail -1 | awk '{print $2}')
	if [ "$tmpdt" != "" ]; then
		lastBlkCreated=$(cli leaders logs get | grep -A1 $tmpdt | tail -1 |awk '{print $2}' | sed s#\"##g | awk '{split($1,blk,".")}{printf "%03d",blk[2]}')
	fi
	tmpdt=$(cli leaders logs get | grep -A2 finished_at_time:\ ~ | grep scheduled_at_time | sort | head -1 | awk '{print $2}')
	if [ "$tmpdt" != "" ]; then
		nextBlkSched=$(cli leaders logs get | grep -B1 $tmpdt | head -1 |awk '{print $2}' | sed s#\"##g | awk '{split($0,blk,".")}{printf "%03d",blk[2]}')
	fi
	usedMem=$(free -mt | tail -1 | awk '{printf "%d", $3}')
	nodesEstablished=$(cli network stats get --output-format json | jq '. | length')
	nodesEstablishedUnique=$(sudo netstat -anlp | egrep "ESTABLISHED+.*jormungandr" | cut -c 45-68 | cut -d ":" -f 1 | sort | uniq -c | wc -l)
	#nodesSynSent=$(sudo netstat -anlp 2>/dev/null | egrep "SYN_SENT+.*jormungandr" | cut -c 45-68 | cut -d ":" -f 1 | sort | uniq | wc -l)
	currentTip=$(cli tip get | cut -c1-3 | od -A n -t x1 | awk '{ print $1$2$3 }')
	lostBlocks=$(python3 lostblocks.py -r "${JORMUNGANDR_RESTAPI_URL}")
elif [ "$(uname -s)" == "Darwin" ]; then
	lastBlockDateSlot=$(cli node stats get --output-format json | jq -r .lastBlockDate | cut -f2 -d.)
	blockRecvCnt=$(cli node stats get --output-format json | jq -r .blockRecvCnt)
	lastBlockHeight=$(cli node stats get --output-format json | jq -r .lastBlockHeight)
	uptime=$(cli node stats get --output-format json | jq -r .uptime)
	lastBlockTx=$(cli node stats get --output-format json | jq -r .lastBlockTx)
	txRecvCnt=$(cli node stats get --output-format json | jq -r .txRecvCnt)
	productionInEpoch=$(cli leaders logs get --output-format json | jq ' group_by(.scheduled_at_date | split(".")[0])[-1] |  .[]? | if .finished_at_time != null then 1 else 0 end' | awk '{sum+=$0} END{print sum}')
	tmpdt=$(cli leaders logs get | grep finished_at_ | sort | grep -v \~ | tail -1 | awk '{print $2}')
	if [ "$tmpdt" != "" ]; then
		lastBlkCreated=$(cli leaders logs get | grep -A1 $tmpdt | tail -1 |awk '{print $2}' | sed s#\"##g | awk '{split($1,blk,".")}{printf "%03d",blk[2]}')
	fi
	tmpdt=$(cli leaders logs get | grep -A2 finished_at_time:\ ~ | grep scheduled_at_time | sort | head -1 | awk '{print $2}')
	if [ "$tmpdt" != "" ]; then
		nextBlkSched=$(cli leaders logs get | grep -B1 $tmpdt | head -1 |awk '{print $2}' | sed s#\"##g | awk '{split($1,blk,".")}{printf "%03d",blk[2]}')
	fi
	usedMem=$(top -l 1 | grep used | awk '{print $4}' | tr -d -c 0-9)
	nodesEstablished=$(cli network stats get --output-format json | jq '. | length')
	nodesEstablishedUnique=$(sudo lsof -Pn -i | egrep "jormungan" |grep ESTABLISHED | cut -c 97-112 | sed -e 's#\(\>\)\(\-\)##g' | cut -d ":" -f 1 | sort | uniq -c | wc -l)
	#nodesSynSent=$(sudo lsof -Pn -i | egrep "jormungan" | grep SYN_SENT  | cut -c 97-112 | sed -e 's#\(\>\)\(\-\)##g' | cut -d ":" -f 1 | sort | uniq -c | wc -l)
	currentTip=$(cli tip get | cut -c1-3 | od -A n -t x1 | awk '{ print $1$2$3 }')
	lostBlocks=$(python3 lostblocks.py -r "${JORMUNGANDR_RESTAPI_URL}")
fi

# default NULL values to 0

if [ "$lastBlockDateSlot" == "" ]; then
	lastBlockDateSlot="0"
fi
if [ "$blockRecvCnt" == "" ]; then
	blockRecvCnt="0"
fi
if [ "$lastBlockHeight" == "" ]; then
	lastBlockHeight="0"
fi
if [ "$uptime" == "" ]; then
	uptime="0"
fi
if [ "$lastBlockTx" == "" ]; then
	lastBlockTx="0"
fi
if [ "$txRecvCnt" == "" ]; then
	txRecvCnt="0"
fi
if [ "$productionInEpoch" == "" ]; then
	productionInEpoch="0"
fi
if [ "$lastBlkCreated" == "" ]; then
	lastBlkCreated="0"
fi
if [ "$nextBlkSched" == "" ]; then
	nextBlkSched="0"
fi
if [ "$usedMem" == "" ]; then
        usedMem="0"
fi
if [ "$nodesEstablished" == "" ]; then
	nodesEstablished="0"
fi
if [ "$nodesEstablishedUnique" == "" ]; then
	nodesEstablishedUnique="0"
fi
if [ "$nodesSynSent" == "" ]; then
	nodesSynSent="0"
fi
if [ "$currentTip" == "" ]; then
	currentTip="0"
fi
if [ "$lostBlocks" == "" ]; then
	lostBlocks="0"
fi

# return a JSON dataset as required for PRTG Monitoring
echo {\"prtg\": {\"result\": [{\"channel\": \"usedMem\", \"value\": \"${usedMem}\", \"unit\": \"custom\", \"customunit\": \"MB\" }, {\"channel\": \"nodesEstablished\", \"value\": \"${nodesEstablished}\", \"unit\": \"custom\", \"customunit\": \"nodes\" }, {\"channel\": \"nodesEstablishedUnique\", \"value\": \"${nodesEstablishedUnique}\", \"unit\": \"custom\", \"customunit\": \"nodes\" }, {\"channel\": \"lostBlocks\", \"value\": \"${lostBlocks}\", \"unit\": \"custom\", \"customunit\": \"blks\" }, {\"channel\": \"lastBlockDateSlot\", \"value\": \"${lastBlockDateSlot}\", \"unit\": \"custom\", \"customunit\": \"blks\" }, {\"channel\": \"blockRecvCnt\", \"value\": \"${blockRecvCnt}\", \"unit\": \"custom\", \"customunit\": \"blks\" }, {\"channel\": \"lastBlockHeight\", \"value\": \"${lastBlockHeight}\", \"unit\": \"custom\", \"customunit\": \"blks\" }, {\"channel\": \"uptime\", \"value\": \"${uptime}\", \"unit\": \"custom\", \"customunit\": \"sec\" }, {\"channel\": \"lastBlockTx\", \"value\": \"${lastBlockTx}\", \"unit\": \"custom\", \"customunit\": \"tx\" }, {\"channel\": \"txRecvCnt\", \"value\": \"${txRecvCnt}\", \"unit\": \"custom\", \"customunit\": \"tx\" }, {\"channel\": \"productionInEpoch\", \"value\": \"${productionInEpoch}\", \"unit\": \"custom\", \"customunit\": \"blks\" }, {\"channel\": \"lastBlkCreated\", \"value\": \"${lastBlkCreated}\", \"unit\": \"custom\", \"customunit\": \"blks\" }, {\"channel\": \"nextBlkSched\", \"value\": \"${nextBlkSched}\", \"unit\": \"custom\", \"customunit\": \"blks\" }, {\"channel\": \"currentTip\", \"value\": \"${currentTip}\" } ]}} # | python -m json.tool
