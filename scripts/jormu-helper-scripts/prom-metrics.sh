#!/bin/bash

# localhost:9090/metrics poor man solution would be to run this with socat:
# socat TCP-LISTEN:9090,crlf,reuseaddr,fork     SYSTEM:"echo HTTP/1.1 200 OK;SERVED=true bash /tmp/get-metrics;"
# More info on prom-comptible output: https://github.com/prometheus/docs/blob/master/content/docs/instrumenting/exposition_formats.md

exec 2>/dev/null
function get-metrics() {
  shopt -s expand_aliases
  if [ ! -z "$SERVED" ]
  then
    echo "Content-type: text/plain" # Tells the browser what kind of content to expect
    echo "" # request body starts from this empty line
  fi
  # Replace the value for URL as appropriate
  RESTAPI_PORT=8443
  if [ ! $JORMUNGANDR_RESTAPI_URL ]; then export JORMUNGANDR_RESTAPI_URL=http://127.0.0.1:${RESTAPI_PORT}/api; fi
  alias cli="$(which jcli) rest v0"

  # Node stats data

  if [ "$(uname -s)" == "Linux" ]; then
    export METRIC_lastBlockDateSlot=$(cli node stats get --output-format json | jq -r .lastBlockDate | cut -f2 -d.)
    export METRIC_blockRecvCnt=$(cli node stats get --output-format json | jq -r .blockRecvCnt)
    export METRIC_lastBlockHeight=$(cli node stats get --output-format json | jq -r .lastBlockHeight)
    export METRIC_uptime=$(cli node stats get --output-format json | jq -r .uptime)
    export METRIC_lastBlockTx=$(cli node stats get --output-format json | jq -r .lastBlockTx)
    export METRIC_txRecvCnt=$(cli node stats get --output-format json | jq -r .txRecvCnt)
    export METRIC_productionInEpoch=$(cli leaders logs get --output-format json | jq ' group_by(.scheduled_at_date | split(".")[0])[-1] |  .[]? | if .finished_at_time != null then 1 else 0 end' | awk '{sum+=$0} END{print sum}')
    export METRIC_usedMem=$(free -mt | tail -1 | awk '{printf "%d", $3}')
    export METRIC_nodesEstablished=$(cli network stats get --output-format json | jq '. | length')
    export METRIC_nodesEstablishedUnique=$(sudo netstat -anlp | egrep "ESTABLISHED+.*jormungandr" | cut -c 45-68 | cut -d ":" -f 1 | sort | uniq -c | wc -l)
    export METRIC_currentTip=$(cli tip get | cut -c1-3 | od -A n -t x1 | awk '{ print $1$2$3 }')
    export METRIC_lostBlocks=$(python3 lostblocks.py -r "${JORMUNGANDR_RESTAPI_URL}" 2>/dev/null)
    #export METRIC_nodesSynSent=$(sudo netstat -anlp 2>/dev/null | egrep "SYN_SENT+.*jormungandr" | cut -c 45-68 | cut -d ":" -f 1 | sort | uniq | wc -l)
    tmpdt=$(cli leaders logs get | grep finished_at_ | sort | grep -v \~ | tail -1 | awk '{print $2}')
    test ! -z "${tmpdt}" && METRIC_lastBlkCreated=$(cli leaders logs get | grep -A1 $tmpdt | tail -1 |awk '{print $2}' | sed s#\"##g | awk '{split($1,blk,".")}{printf "%03d",blk[2]}')
    tmpdt=$(cli leaders logs get | grep -A2 finished_at_time:\ ~ | grep scheduled_at_time | sort | head -1 | awk '{print $2}')
    test ! -z "${tmpdt}" && METRIC_nextBlkSched=$(cli leaders logs get | grep -B1 $tmpdt | head -1 |awk '{print $2}' | sed s#\"##g | awk '{split($0,blk,".")}{printf "%03d",blk[2]}')
  elif [ "$(uname -s)" == "Darwin" ]; then
    export METRIC_lastBlockDateSlot=$(cli node stats get --output-format json | jq -r .lastBlockDate | cut -f2 -d.)
    export METRIC_blockRecvCnt=$(cli node stats get --output-format json | jq -r .blockRecvCnt)
    export METRIC_lastBlockHeight=$(cli node stats get --output-format json | jq -r .lastBlockHeight)
    export METRIC_uptime=$(cli node stats get --output-format json | jq -r .uptime)
    export METRIC_lastBlockTx=$(cli node stats get --output-format json | jq -r .lastBlockTx)
    export METRIC_txRecvCnt=$(cli node stats get --output-format json | jq -r .txRecvCnt)
    export METRIC_productionInEpoch=$(cli leaders logs get --output-format json | jq ' group_by(.scheduled_at_date | split(".")[0])[-1] |  .[]? | if .finished_at_time != null then 1 else 0 end' | awk '{sum+=$0} END{print sum}')
    export METRIC_usedMem=$(top -l 1 | grep used | awk '{print $4}' | tr -d -c 0-9)
    export METRIC_nodesEstablished=$(cli network stats get --output-format json | jq '. | length')
    export METRIC_nodesEstablishedUnique=$(sudo lsof -Pn -i | egrep "jormungan" |grep ESTABLISHED | cut -c 97-112 | sed -e 's#\(\>\)\(\-\)##g' | cut -d ":" -f 1 | sort | uniq -c | wc -l)
    export METRIC_currentTip=$(cli tip get | cut -c1-3 | od -A n -t x1 | awk '{ print $1$2$3 }')
    export METRIC_lostBlocks=$(python3 lostblocks.py -r "${JORMUNGANDR_RESTAPI_URL}")
    #export METRIC_nodesSynSent=$(sudo lsof -Pn -i | egrep "jormungan" | grep SYN_SENT  | cut -c 97-112 | sed -e 's#\(\>\)\(\-\)##g' | cut -d ":" -f 1 | sort | uniq -c | wc -l)
    tmpdt=$(cli leaders logs get | grep finished_at_ | sort | grep -v \~ | tail -1 | awk '{print $2}')
    test ! -z "${tmpdt}" &&  METRIC_lastBlkCreated=$(cli leaders logs get | grep -A1 $tmpdt | tail -1 |awk '{print $2}' | sed s#\"##g | awk '{split($1,blk,".")}{printf "%03d",blk[2]}')
    tmpdt=$(cli leaders logs get | grep -A2 finished_at_time:\ ~ | grep scheduled_at_time | sort | head -1 | awk '{print $2}')
    test ! -z "${tmpdt}" &&  METRIC_nextBlkSched=$(cli leaders logs get | grep -B1 $tmpdt | head -1 |awk '{print $2}' | sed s#\"##g | awk '{split($1,blk,".")}{printf "%03d",blk[2]}')
  fi

  for metric_var_name in $(env | grep ^METRIC | awk -F= '{print $1}')
  do
    METRIC_NAME=$(echo $metric_var_name | sed 's|METRIC_||g')
    # default NULL values to 0
    if [ -z "${!metric_var_name}" ]
    then
      METRIC_VALUE="0"
    else
      METRIC_VALUE="${!metric_var_name}"
    fi
    echo $METRIC_NAME $METRIC_VALUE
  done
}

get-metrics
