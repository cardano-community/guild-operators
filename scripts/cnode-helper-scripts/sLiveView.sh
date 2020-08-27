#!/bin/bash
#shellcheck disable=SC2009

# Credits to original Author of the script : Adam Dean (from BUFFY | SPIKE pool) by Crypto2099

#####################################
# Change variables below as desired #
#####################################

# The commands below will try to detect the information assuming you run single node on a machine. Please override values if they dont match your system

cardanoport=$(ps -ef | grep "[c]ardano-node.*.port" | awk -F 'port ' '{print $2}' | awk '{print $1}') # example value: 6000
nodename="RTFM Lazy Guy" # Change your node's name prefix here, 22 character limit!!!
refreshrate=2 # How often (in seconds) to refresh the view
config=$(ps -ef | grep "[c]ardano-node.*.config" | awk -F 'config ' '{print $2}' | awk '{print $1}') # example: /opt/cardano/cnode/files/config.json
if [[ -f "$config" ]]; then
  promport=$(jq -r '.hasPrometheus[1] //empty' "$config" 2>/dev/null)
else
  promport=12798
fi


#####################################
# Do NOT Modify below               #
#####################################


version=$("$(command -v cardano-node)" version)
node_version=$(grep -oP '(?<=cardano-node )[0-9\.]+' <<< "${version}")
node_rev=$(grep -oP '(?<=rev )[a-z0-9]+' <<< "${version}" | cut -c1-8)

node_version=$(printf "%14s" "$node_version")
node_rev=$(printf "%14s" "$node_rev")
#name=$(printf "%*s\n" $((36)) "$nodename")

# Add some colors
REKT='\033[1;31m'
GOOD='\033[0;32m'
NC='\033[0m'
INFO='\033[1;34m'

while true
do
  data=$(curl localhost:$promport/metrics 2>/dev/null)
  remotepeers=$(netstat -an|awk "\$4 ~ /${cardanoport}/"|grep -c ESTABLISHED)
  peers=$(grep -oP '(?<=cardano_node_BlockFetchDecision_peers_connectedPeers_int )[0-9]+' <<< "${data}")
  blocknum=$(grep -oP '(?<=cardano_node_ChainDB_metrics_blockNum_int )[0-9]+' <<< "${data}")
  epochnum=$(grep -oP '(?<=cardano_node_ChainDB_metrics_epoch_int )[0-9]+' <<< "${data}")
  slotnum=$(grep -oP '(?<=cardano_node_ChainDB_metrics_slotNum_int )[0-9]+' <<< "${data}")
  uptimens=$(grep -oP '(?<=cardano_node_metrics_upTime_ns )[0-9]+' <<< "${data}")
  density=$(grep -oP '(?<=cardano_node_ChainDB_metrics_density_real )[0-9]+' <<< "${data}")
  transactions=$(grep -oP '(?<=cardano_node_metrics_txsProcessedNum_int )[0-9]+' <<< "${data}")
  kesperiod=$(grep -oP '(?<=cardano_node_Forge_metrics_currentKESPeriod_int )[0-9]+' <<< "${data}")
  kesremain=$(grep -oP '(?<=cardano_node_Forge_metrics_remainingKESPeriods_int )[0-9]+' <<< "${data}")
  isleader=$(grep -oP '(?<=cardano_node_metrics_Forge_node_is_leader_int )[0-9]+' <<< "${data}")
  abouttolead=$(grep -oP '(?<=cardano_node_metrics_Forge_forge_about_to_lead_int )[0-9]+' <<< "${data}")
  forged=$(grep -oP '(?<=cardano_node_metrics_Forge_forged_int )[0-9]+' <<< "${data}")

  if [[ $abouttolead -gt 0 ]]; then
    name=$(printf "%s - Core\n" "$nodename")
  else
    name=$(printf "%s - Relay\n" "$nodename")
  fi

  if ((uptimens<=0)); then
    echo -e "${REKT}COULD NOT CONNECT TO A RUNNING INSTANCE! PLEASE CHECK THE PROMETHEUS PORT AND TRY AGAIN!${NC}"
    exit
  fi

#  remotepeers=$(printf "%14s" "$remotepeers")
  peers=$(printf "%14s" "$peers / $remotepeers")
  epoch=$(printf "%14s" "$epochnum / $blocknum")
  slot=$(printf "%14s" "$slotnum")
  txcount=$(printf "%14s" "$transactions")
  density=$(printf "%12s %%" "$density")

  if [[ isleader -lt 0 ]]; then
    isleader=0
    forged=0
  fi

  uptimes=$(( uptimens / 1000000000))
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

  day=$(printf "%02d\n" "$day")
  hour=$(printf "%02d\n" "$hour")
  min=$(printf "%02d\n" "$min")
  sec=$(printf "%02d\n" "$sec")

  uptime="$day":"$hour":"$min":"$sec"
  uptime=$(printf "%14s" "$uptime")

  clear
  echo -e '+--------------------------------------+'
  echo -e '|           Simple Node Stats          |'
  echo -e '+---------------------+----------------+'
  if [[ -n "$nodename" ]]; then
    name=$(printf "%30s" "${name}")
    echo -e "| Name: ${INFO}${name}${NC} |"
    echo -e '+---------------------+----------------+'
  fi
  echo -e "| Version             | ${INFO}${node_version}${NC} |"
  echo -e '+---------------------+----------------+'
  echo -e "| Revision            | ${INFO}${node_rev}${NC} |"
  echo -e '+---------------------+----------------+'
  echo -e "| Peers (Out / In)    | ${peers} |"
  echo -e "+---------------------+----------------+"
  echo -e "| Epoch / Block       | ${epoch} |"
  echo -e '+---------------------+----------------+'
  echo -e "| Slot                | ${slot} |"
  echo -e '+---------------------+----------------+'
  echo -e "| Density             | ${density} |"
  echo -e '+---------------------+----------------+'
  echo -e "| Uptime (D:H:M:S)    | ${uptime} |"
  echo -e '+---------------------+----------------+'
  echo -e "| Transactions        | ${txcount} |"
  echo -e '+---------------------+----------------+'
  if [[ $abouttolead -gt 0 ]]; then
    kesperiod=$(printf "%14s" "$kesperiod")
    kesremain=$(printf "%14s" "$kesremain")
    isleader=$(printf "%14s" "$isleader")
    forged=$(printf "%14s" "$forged")
    echo -e "|  ${GOOD}RUNNING IN BLOCK PRODUCER MODE! :)${NC}  |"
    echo -e "+---------------------+----------------+"
    echo -e "| KES PERIOD          | ${kesperiod} |"
    echo -e "+---------------------+----------------+"
    echo -e "| KES REMAINING       | ${kesremain} |"
    echo -e "+---------------------+----------------+"
    echo -e "| SLOTS LED           | ${isleader} |"
    echo -e "+---------------------+----------------+"
    echo -e "| BLOCKS FORGED       | ${forged} |"
    echo -e "+---------------------+----------------+"
  else
    echo -e "|  ${REKT}NOT A BLOCK PRODUCER! RELAY ONLY!${NC}   |"
    echo -e '+--------------------------------------+'
  fi


  echo -e "\n${INFO}Press [CTRL+C] to stop...${NC}"
  sleep $refreshrate
done

