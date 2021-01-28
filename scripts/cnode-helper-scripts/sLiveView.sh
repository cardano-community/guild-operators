#!/bin/bash
#shellcheck disable=SC2009,SC2034

# Credits to original Author of the script : Adam Dean (from BUFFY | SPIKE pool) by Crypto2099

#####################################
# Change variables below as desired #
#####################################

# The commands below will try to detect the information assuming you run single node on a machine. Please override values if they dont match your system

cardanoport=$(ps -ef | grep "[c]ardano-node.*.port" | awk -F 'port ' '{print $2}' | awk 'NR==1{print $1}') # example value: 6000
nodename="RTFM Lazy Guy" # Change your node's name prefix here, 24 character limit!!!
refreshrate=2 # How often (in seconds) to refresh the view
config=$(ps -ef | grep "[c]ardano-node.*.config" | awk -F 'config ' '{print $2}' | awk 'NR==1{print $1}') # example: /opt/cardano/cnode/files/config.json
ekghost=127.0.0.1
if [[ -f "${config}" ]]; then
  ekgport=$(jq -r '.hasEKG //empty' "${config}" 2>/dev/null)
else
  ekgport=12788
fi


#####################################
# Do NOT Modify below               #
#####################################


version=$("$(command -v cardano-node)" version)
node_version=$(grep -oP '(?<=cardano-node )[0-9\.]+' <<< "${version}")
node_rev=$(grep -oP '(?<=rev )[a-z0-9]+' <<< "${version}" | cut -c1-8)

node_ver=$(printf "%17s" "${node_version} / ${node_rev}")

#node_version=$(printf "%14s" "${node_version}")
#node_rev=$(printf "%14s" "${node_rev}")

# Add some colors
REKT='\033[1;31m'
GOOD='\033[0;32m'
NC='\033[0m'
INFO='\033[1;34m'
while true
do
  data=$(curl -s -H 'Accept: application/json' http://${ekghost}:${ekgport}/ 2>/dev/null)
  remotepeers=$(netstat -an|awk "\$4 ~ /${cardanoport}/"|grep -c ESTABLISHED)
  peers=$(jq '.cardano.node.metrics.connectedPeers.int.val //0' <<< "${data}")
  blocknum=$(jq '.cardano.node.metrics.blockNum.int.val //0' <<< "${data}")
  epochnum=$(jq '.cardano.node.metrics.epoch.int.val //0' <<< "${data}")
  slotnum=$(jq '.cardano.node.metrics.slotInEpoch.int.val //0' <<< "${data}")
  density=$(jq -r '.cardano.node.metrics.density.real.val //0' <<< "${data}")
  uptimens=$(jq '.rts.gc.wall_ms.val //0' <<< "${data}")
  transactions=$(jq '.cardano.node.metrics.txsProcessedNum.int.val //0' <<< "${data}")
  kesperiod=$(jq '.cardano.node.metrics.currentKESPeriod.int.val //0' <<< "${data}")
  kesremain=$(jq '.cardano.node.metrics.remainingKESPeriods.int.val //0' <<< "${data}")
  isleader=$(jq '.cardano.node.metrics.Forge["node-is-leader"].int.val //0' <<< "${data}")
  abouttolead=$(jq '.cardano.node.metrics.Forge["forge-about-to-lead"].int.val //0' <<< "${data}")
  forged=$(jq '.cardano.node.metrics.Forge.forged.int.val //0' <<< "${data}")
  adopted=$(jq '.cardano.node.metrics.Forge.adopted.int.val //0' <<< "${data}")

  if [[ ${abouttolead} -gt 0 ]]; then
    name=$(printf "%s - Core\n" "${nodename}")
  else
    name=$(printf "%s - Relay\n" "${nodename}")
  fi

  if ((uptimens<=0)); then
    echo -e "${REKT}COULD NOT CONNECT TO A RUNNING INSTANCE! PLEASE CHECK THE PROMETHEUS PORT AND TRY AGAIN!${NC}"
    exit
  fi

#  remotepeers=$(printf "%14s" "${remotepeers}")
  runport=$(printf "%17s" "${cardanoport}")
  peers=$(printf "%17s" "${peers} / ${remotepeers}")
  epoch=$(printf "%17s" "${epochnum} / ${slotnum}")
  block=$(printf "%17s" "${blocknum}")
  txcount=$(printf "%17s" "${transactions}")
  density=$(printf "%15.4s %%" "${density}"*100)

  if [[ isleader -lt 0 ]]; then
    isleader=0
    forged=0
  fi

  uptimes=$(( uptimens / 1000))
  min=0
  hour=0
  day=0
  if((uptimes > 59)); then
    ((sec=uptimes%60))
    ((uptimes=uptimes/60))
    if((uptimes > 59)); then
      ((min=uptimes%60))
      ((uptimes=uptimes/60))
      if((uptimes > 23)); then
        ((hour=uptimes%24))
        ((day=uptimes/24))
      else
        ((hour=uptimes))
      fi
    else
      ((min=uptimes))
    fi
  else
    ((sec=uptimes))
  fi

  day=$(printf "%02d\n" "${day}")
  hour=$(printf "%02d\n" "${hour}")
  min=$(printf "%02d\n" "${min}")
  sec=$(printf "%02d\n" "${sec}")

  uptime="${day}":"${hour}":"${min}":"${sec}"
  uptime=$(printf "%17s" "${uptime}")

  clear
  echo -e "+-------------------------------------------+"
  echo -e "|              ${INFO}Simple Node Stats${NC}            |"
  echo -e "+-------------------------------------------+"
  if [[ -n "${nodename}" ]]; then
    name=$(printf "%35s" "${name}")
    echo -e "| Name: ${INFO}${name}${NC} |"
    echo -e "+-----------------------+-------------------+"
  fi
  echo -e "| Version / Revision    | ${INFO}${node_ver}${NC} |"
#  echo -e "| Version               | ${INFO}${node_version}${NC} |"
#  echo -e '+-----------------------+-------------------+'
#  echo -e "| Revision              | ${INFO}${node_rev}${NC} |"
  echo -e "+-----------------------+-------------------+"
  echo -e "| Port                  | ${INFO}${runport}${NC} |"
  echo -e "+-----------------------+-------------------+"
  echo -e "| Peers (Out / In)      | ${peers} |"
  echo -e "+-----------------------+-------------------+"
  echo -e "| Epoch / Slot          | ${epoch} |"
  echo -e "+-----------------------+-------------------+"
  echo -e "| Block                 | ${block} |"
  echo -e "+-----------------------+-------------------+"
  echo -e "| Density               | ${density} |"
  echo -e "+-----------------------+-------------------+"
  echo -e "| Uptime (D:H:M:S)      | ${uptime} |"
  echo -e "+-----------------------+-------------------+"
  echo -e "| Transactions          | ${txcount} |"
  echo -e "+-----------------------+-------------------+"
  if [[ ${abouttolead} -gt 0 ]]; then
    kesperiod=$(printf "%17s" "${kesperiod}")
    kesremain=$(printf "%17s" "${kesremain}")
    isleader=$(printf "%17s" "${isleader}")
    forged=$(printf "%17s" "${forged}/${adopted}")
    echo -e "| KES PERIOD            | ${kesperiod} |"
    echo -e "+-----------------------+-------------------+"
    echo -e "| KES REMAINING         | ${kesremain} |"
    echo -e "+-----------------------+-------------------+"
    echo -e "| SLOTS LED             | ${isleader} |"
    echo -e "+-----------------------+-------------------+"
    echo -e "| BLOCKS FORGED/ADOPTED | ${forged} |"
    echo -e "+-----------------------+-------------------+"
  else
    echo -e "+-------------------------------------------+"
  fi


  echo -e "\n${INFO}Press [CTRL+C] to stop...${NC}"
  sleep ${refreshrate}
done

