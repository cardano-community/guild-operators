#!/bin/bash

# This script takes the first event identified as fisrt time block seen and stores it in a 5k file (/tmp/block_index.log) ready to be digested in our case by loki in grafana.
# 
# This script was built with the intent to use the guild_operators work (including cntools) ready out of the box.
#

touch  /tmp/block_list
truncate -s 0 /tmp/block_list;
truncate -s 0 /tmp/block_index.log;
touch /tmp/block_index.idx
touch /tmp/block_index.log
truncate -s 0 /tmp/block_index.log;

GREP=$(grep headerHash /opt/cardano/cnode/logs/node-0.json | jq .data.block.headerHash | uniq | grep -v null | cut -d "\"" -f 2 > /tmp/block_list)
GREP2=$(grep TraceAdoptedBlock /opt/cardano/cnode/logs/node-0.json | jq .data.blockHash | sort | uniq | grep -v null | cut -d "\"" -f 2 >> /tmp/block_list)

for i in $(cat /tmp/block_list); do 
grep $i /tmp/block_index.idx > /dev/null; QRESU=$?;
if [[ $QRESU -gt 0 ]]; then
    BLOCK=$(cat /opt/cardano/cnode/logs/node-0.json | grep $i | head -n 1);
    BLOCK2=$(cat /opt/cardano/cnode/logs/node-0.json | grep TraceAdoptedBlock | grep $i | head -n 1);
    echo $BLOCK >> /tmp/block_index.log;
    echo $BLOCK >> /tmp/block_index.idx;
    if [ ! -z "$BLOCK2" ]; then 
    echo $BLOCK2 >> /tmp/block_index.log;
    echo $BLOCK2 >> /tmp/block_index.idx;
    else 
    echo "No TraceAdoptedBlock"; 
    fi
fi
done

tail -n 5000 /tmp/block_index.idx > /tmp/block_index.idx2
mv /tmp/block_index.idx2 /tmp/block_index.idx
