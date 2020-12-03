#!/bin/bash
 
export CNODE_HOME=/opt/cardano/cnode

truncate -s 0  /tmp/ip2trace_out.log;
truncate -s 0  /tmp/ip2trace_in.log;

pHOST=$HOSTNAME
pIP=$(ifconfig eth0  | grep inet | grep -v inet6 | awk '{print $2}')
pPORT=$(ps ax | grep "cardano-node run" | grep -v grep |sed 's/[^ ].*port //' | awk '{print $1}')

netstat -nt  | grep tcp | grep EST | grep "$pIP:$pPORT" | awk '{ print $5 }' | cut -d ':' -f 1 | grep -v 172 > /tmp/iptrace_list_in.csv
netstat -nt  | grep tcp | grep EST | grep "$pIP:$pPORT" | awk '{ print $5 }' | cut -d ':' -f 1 | grep 172 > /tmp/iptrace_list_in_local.csv
netstat -nt  | grep tcp | grep EST | grep -v "$pIP:$pPORT" | awk '{ print $5 }' | cut -d ':' -f 1 | grep -v 172 > /tmp/iptrace_list_out.csv
netstat -nt  | grep tcp | grep EST | grep -v "$pIP:$pPORT" | awk '{ print $5 }' | cut -d ':' -f 1 | grep 172 > /tmp/iptrace_list_out_local.csv
sleep 3 2>&1; 

/usr/local/bin/ip2location -list /tmp/iptrace_list_in.csv -t all > /tmp/ip2trace_list_in.plog
sleep 2;
/usr/local/bin/ip2location -list /tmp/iptrace_list_out.csv -t all > /tmp/ip2trace_list_out.plog


LinesIN=$(cat /tmp/ip2trace_list_in.plog | wc -l)
LinesOUT=$(cat /tmp/ip2trace_list_out.plog | wc -l)
timestamp=$(date +%D)
time=$(date +%T)
for ((i=1;i<=$LinesIN;i++)); do ADD=$(sed -n "$i"p /tmp/ip2trace_list_in.plog); echo "timestamp=$timestamp,time=$time,pHOST=$pHOST,pIP=$pIP,pPORT=$pPORT,app=$ADD" | sed s/" country_long"/",country_long"/g | sed s/" "/"_"/g | sed s/","/" "/g | sed s/"\""/""/g >> /tmp/ip2trace_in.log; done
for ((i=1;i<=$LinesOUT;i++)); do ADD=$(sed -n "$i"p /tmp/ip2trace_list_out.plog); echo "timestamp=$timestamp,time=$time,pHOST=$pHOST,pIP=$pIP,pPORT=$pPORT,app=$ADD" | sed s/" country_long"/",country_long"/g | sed s/" "/"_"/g | sed s/","/" "/g | sed s/"\""/""/g >> /tmp/ip2trace_out.log; done
