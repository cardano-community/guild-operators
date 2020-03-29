#!/bin/bash

# WARNING:
# - If you're not sure what the script does, please do not use it directly on the network. Incorrect implementation may cause you to create an adversarial fork and (correctly) report you accordingly on some community sites

# DISCLAIMER:
# - The script works for a specific 1-pool with 2-nodes scenario. It is expected that you customise this to your environment and usage.
# - While the actual script is pretty basic in nature, It is assumed that someone using this method is well equipped and qualifies as per the skills and requirements expected of a stakepool operator in the URL below:
#      https://testnet.iohkdev.io/en/cardano/shelley/about/skills-and-requirements/
# - The most important outcome is to prevent having multiple nodes exhibiting same key at a time, except for epoch transition. 
# - We are learning and testing the script (so far the results have been satisfying), please do feel free to add any feedbacks/suggestions to github repo itself
# - Do not expect any tech support from IOHK Help Desk/official support mediums on the script, it is made by the community - for the community
# - Be careful when testing against builds that face issues with hung API calls, you could end up with adversarial fork because API didnt give back a reply.

# How nodes are started?
# - The case below expects that the two leaders are started with their keys during boot up time.
# - Example script that can be created to deploy to systemd (1 for each node):
#   cat ~/jormu/scripts/itn1.sh
#     #!/bin/bash
#     while true; do
#         jormungandr --config itn1.yaml --genesis-block-hash $(cat ~/jormu/files/ genesis.hash) --secret ~/jormu/priv/pool-secret.yaml > ~/jormu/logs/node1.log 2>&1
#     done
# - Example systemd script that can be created to run as service (1 for each node):
#   cat /etc/systemd/system/itn1.service
#     [Unit]
#     Description=Jormungandr ITN Service
#     After=network.target
#     
#     [Service]
#     User=username
#     Group=username
#     Type=simple
#     Restart=on-failure
#     ExecStart=/bin/bash -l -c 'exec /home/username/jormu/scripts/itn1.sh 2>&1'
#     WorkingDirectory=/home/username/jormu/scripts
#     LimitNOFILE=350000
#     [Install]
#     WantedBy=multi-user.target

# How script is run?
# Ideally you'd want to run the script in a tmux/screen session so that you can resume the output and check the last timestamps for the type of logging based on event

clear
shopt -s expand_aliases

##########################
# Variables to modify
##########################

autorestart="Y" # To restart the node that's behind 
jkey=~/jormu/priv/pool-secret.yaml
pooltoolreportmode=1 # 0: Dont report, 1: Report status without leadership info, 2: Report status with leadership stats
POOLTOOL_UID_FILE=~/jormu/priv/pooltool.uid # Grab this by login to https://pooltool.io/profile
J1_URL=http://127.0.0.1:4100/api ## Assumes two nodes operating on same host on different ports, change to method as desired
J2_URL=http://127.0.0.1:4101/api ## It is *NOT* recommended to publish your API endpoint to non trusted client connections
timeout=300 # Number of iterations before taking action on node that's behind, no reason to reduce this if your node is working fine
jlogsf=~/jormu/logs #folder for leader history and temporary files

##########################
# Do not modify below
##########################

POOL_ID=$(grep node_id $jkey |awk '{print $2}') # assumes you use the YAML2 (default) format for your node keys
platformName="jormungandr-leaders-failover.sh"
jsettingsf="$jlogsf/.settings.delme"
j1statsf="$jlogsf/.stats1.delme"
j2statsf="$jlogsf/.stats2.delme"
pooltoolf="$jlogsf/.pooltoolresponse.delme"
# Counters
i=0
j=1
newepoch=0

# Function to set/swap Leader URL vars
function echom() {
  echo -en "\033[K\033[$1B\r$(date +%d/%m-%T) - ${@:2}\033[K\033[$1A\r"
}

setURLvars() {
  J1_URL=$1
  J2_URL=$2
}

# Collect chain settings
jcli rest v0 settings get --output-format json -h $J1_URL > $jsettingsf
rc=$?
if [ $rc -ne 0 ]; then
  setURLvars $J2_URL $J1_URL
  jcli rest v0 settings get --output-format json -h $J1_URL > $jsettingsf
  if [ $rc -ne 0 ]; then
    echo "Atleast one of the nodes needs to be up and responding before starting this script!"
    exit 1
  fi
fi
slotDuration=$(cat $jsettingsf | jq -r .slotDuration)
slotsPerEpoch=$(cat $jsettingsf | jq -r .slotsPerEpoch)
GENESIS=$(cat $jsettingsf | jq -r .block0Hash)
jormVersion=$(jcli rest v0 node stats get --output-format json -h $J1_URL | jq -r .version)
rm -f /tmp/.jormu_settings.delme

# Initial screen for echo
echom 1 "Status: Date: <NA> Height: <NA> Active: $(echo $J1_URL |cut -d/ -f3|cut -d: -f2)"
echom 2 "Last Sync Difference: <NA>"
echom 3 "Leader key moved to node at port: $(echo $J1_URL |cut -d/ -f3|cut -d: -f2)"
echom 4 "Last Pooltool response: <NA>"

exec 2>$jlogsf/stderr.log

# Main Leader Failover loop , note that the test condition will/should never satisfy - if it did, then you modified something incorrectly below (converse is not true)
while (test "$i" -le $timeout )
do
  jcli rest v0 node stats get --output-format json -h $J1_URL 1>$j1statsf 2>/dev/null
  jcli rest v0 node stats get --output-format json -h $J2_URL 1>$j2statsf 2>/dev/null
  lBH1=$(cat $j1statsf | jq -r .lastBlockHeight)
  lBH2=$(cat $j2statsf | jq -r .lastBlockHeight)
  lBD=$(cat $j1statsf | jq -r .lastBlockDate)
  currslot=$(( (($(date +%s)-1576264417)%($slotsPerEpoch*$slotDuration))/$slotDuration ))
  diffepochend=$(expr $slotsPerEpoch - $currslot)
  if [ -z "${lBH1}" ] || [ "${lBH1}" == "null" ] ;then
    # Expect delete calls to fail, and hence send output of those delete calls to /dev/null.
    jcli rest v0 leaders delete 1 -h $J2_URL >/dev/null 2>&1
    jcli rest v0 leaders post -f $jkey -h $J2_URL >/dev/null 2>&1
    jcli rest v0 leaders delete 1 -h $J1_URL >/dev/null 2>&1
    setURLvars $J2_URL $J1_URL
    echom 1 "Node $(echo $J2_URL |cut -d/ -f3|cut -d: -f2) Down: Height: $lBH2 Active: $(echo $J1_URL |cut -d/ -f3|cut -d: -f2)"
  elif [ -z "${lBH2}" ] || [ "${lBH2}" == "null" ]; then
    sleep $(($slotDuration+1))
    echom 1 "Node $(echo $J2_URL |cut -d/ -f3|cut -d: -f2) Down: Date: $lBD Height: $lBH1 Active: $(echo $J1_URL |cut -d/ -f3|cut -d: -f2)"
  else
    hdiff=$(( $lBH2 - $lBH1 ))
    echom 1 "Status: Date: $lBD Height: $lBH1 Diff: $hdiff Active: $(echo $J1_URL |cut -d/ -f3|cut -d: -f2)"
    # Epoch Transition: Remote (2/43200) probability of creating an adversarial fork if assigned a leadership slot right at the epoch transition
    if [ $diffepochend -lt $(($slotDuration+1)) ]; then
      echom 5 "Last Epoch Transition Status:"
      echom 6 " - Entered: Adding keys, pausing failover capabilities.."
      # Based on this script J1 is active and will always have the leader key, so only add to J2
      jcli rest v0 leaders post -f $jkey -h $J2_URL > /dev/null
      sleep $(($slotDuration+1))
      J1LEADSLOTCNT=0
      J2LEADSLOTCNT=0
      epochtranscnt=0
      while [ "$J1LEADSLOTCNT" -eq 0 -o "$J2LEADSLOTCNT" -eq 0 ]; do
      # Loop waiting for leadership scheduler to fill atleast one slot to new epoch - else use $timeout to proceed
        if [ $epochtranscnt -gt $timeout ]; then
          J2LEADSLOTCNT=-1
          J1LEADSLOTCNT=-1
          echom 8 " - Complete: No slots scheduled for this epoch (timeout reached)"
        else
          echom 7 " - Waiting for Schedule: Iteration - ($((epochtranscnt++))/$timeout) .."
          sleep $(($slotDuration/2))
          J1LEADSLOTCNT=$(jcli rest v0 leaders logs get -h $J1_URL | grep "wake_at_time: ~"  | wc -l)
          J2LEADSLOTCNT=$(jcli rest v0 leaders logs get -h $J2_URL | grep "wake_at_time: ~"  | wc -l)
          if [ $J1LEADSLOTCNT -gt 0 -a $J2LEADSLOTCNT -gt 0 ]; then
            logtmp=$jlogsf/leaders_$(date +%d_%mT%T)
            jcli rest v0 leaders logs get -h $J1_URL | grep -e scheduled -e wake | awk 'NR%3{printf "%s ",$0;next;}1' | sed -e 's/scheduled_at_//g;s/_at_time//g'  | sort -V | column -t | grep \~ > $logtmp
            echom 8 " - Complete: Schedule loaded successfully"
          else
            echom 8 " - Current Leader Slots: J1 - $J1LEADSLOTCNT, J2 - $J2LEADSLOTCNT"
            J1LEADSLOTCNT=0
            J2LEADSLOTCNT=0
          fi
        fi
      done
      jcli rest v0 leaders delete 1 -h $J2_URL > /dev/null
      newepoch=1
    else
      # If not at epoch transition, make sure there is only 1 leader at a time
      # Ensure J1 has only 1 leader ID, delete others
      loopchk=1
      while [ "$loopchk" -eq 1 ]; do
        J1LEADCNT=$(jcli rest v0 leaders get -h $J1_URL | tail -1 | awk '{print $2}')
        loopchk=0
        if [ ! -z "$J1LEADCNT" ]; then
          if [ $J1LEADCNT -gt 1 ]; then
            jcli rest v0 leaders delete $J1LEADCNT -h $J1_URL > /dev/null
            loopchk=1
          fi
        else
          jcli rest v0 leaders post -f $jkey -h $J1_URL > /dev/null
        fi
      done

      # Ensure J2 has no leader keys
      loopchk=1
      while [ "$loopchk" -eq 1 ]; do
        J2LEADCNT=$(jcli rest v0 leaders get -h $J2_URL | tail -1 | awk '{print $2}')
        if [ ! -z "$J2LEADCNT" ]; then
          jcli rest v0 leaders delete 1 -h $J2_URL > /dev/null
        else
          loopchk=0
        fi
      done
    fi

    sleep $(($slotDuration/2))
    if [ "$hdiff" -gt 0 ]; then
      echom 2 "Last Sync Difference: $(echo $J1_URL |cut -d/ -f3|cut -d: -f2) was behind $(echo $J2_URL |cut -d/ -f3|cut -d: -f2) $((i++ + 1)) time(s)"
      # if block height of J1 is behind for consecutive 1.5 slots, swap leadership for 2nd slot
      if [ "$i" -ge 2 ]; then
        echom 3 "Leader key moved to node at port: $(echo $J2_URL |cut -d/ -f3|cut -d: -f2)"
        jcli rest v0 leaders post -f $jkey -h $J2_URL > /dev/null
        jcli rest v0 leaders delete 1 -h $J1_URL > /dev/null
        setURLvars $J2_URL $J1_URL
        i=0
      fi
    elif [ "$hdiff" -lt -5 ]; then
      # if blockheight of J2 is behind by more than 5 blocks for $timeout itertions take action if auto restart is set to yes.
      echom 2 "Last Sync Difference: $(echo $J2_URL |cut -d/ -f3|cut -d: -f2) was behind $(echo $J1_URL |cut -d/ -f3|cut -d: -f2) $((i++ + 1)) time(s)"
      if [ "$i" -ge $timeout ]; then
        if [ "${autorestart}" != "N" ]; then
          jcli rest v0 shutdown get -h $J2_URL > /dev/null
          echom 9 "Last Node Reset due to timeout: $(echo $J2_URL |cut -d/ -f3|cut -d: -f2)" >> $jlogsf/killjormu.log
        fi
        i=0
      fi
    else
      i=0
    fi
  fi
  # Report to Pooltool
  if [ $pooltoolreportmode -gt 0 ]; then
    # If first iteration post epoch transition, Send slots to pooltool - encrypted for current epoch, and key for previous epoch
    if [ $newepoch -gt 0 ]; then
      if [ $pooltoolreportmode -eq 2 ]; then
        #leaderl=$(curl -s ${J1_URL}/v0/leaders/logs)
        leaderl=$(jcli rest v0 leaders logs get --output-format json -h $J1_URL)
        epoch=$(( (($(date +%s)-1576264417) / ($slotsPerEpoch*$slotDuration)) ))
        prevepoch=$((epoch - 1))
        currslots=$(echo "$leaderl" | jq -c '[ .[] | select(.scheduled_at_date | startswith('\"$epoch\"')) ]')
        slotsct=$(echo "$currslots" | jq '. | length')
        if [ -f "${jlogsf}/key_${prevepoch}" ];then
          prevepochkey=$(cat "${jlogsf}"/key_"${prevepoch}")
        else
          prevepochkey=''
        fi
        if [ -f "${jlogsf}"/key_"${epoch}" ];then
          epochkey=$(cat "${jlogsf}"/key_"${epoch}")
        else
          epochkey=$(openssl rand -base64 32 | tee "${jlogsf}"/key_"${epoch}")
        fi
        currslots_enc=$(echo "${currslots}" | gpg --symmetric --armor --batch --passphrase "${epochkey}")
        json="$(jq -n --compact-output --arg epoch "$epoch" --arg poolid "$POOL_ID" --arg uid "$(cat $POOLTOOL_UID_FILE)" --arg genesis "$GENESIS" --arg slotsct "$slotsct" --arg prevepochkey "$prevepochkey" --arg currslots_enc "$currslots_enc" '{currentepoch: $epoch, poolid: $poolid, genesispref: $genesis, userid: $uid, assigned_slots: $slotsct, previous_epoch_key: $prevepochkey, encrypted_slots: $currslots_enc}')"
        rc=$(curl -s -H "Accept: application/json" -H "Content-Type:application/json" -X POST --data "$json" "https://api.pooltool.io/v0/sendlogs")
        echom 9 " - Pooltool Response for slot logs: $rc"
      fi
      newepoch=0
    fi
    # Report tip to Pooltool
    if [ $(( j++ + 1)) -gt 8 ]; then
      lastBlockHash=$(cat $j1statsf | jq -r .lastBlockHash)
      lastBlock=$(jcli rest v0 block ${lastBlockHash} get -h $J1_URL 2>/dev/null)
      lastPoolID=${lastBlock:168:64}
      lastParent=${lastBlock:104:64}
      lastSlot=$((0x${lastBlock:24:8}))
      lastEpoch=$((0x${lastBlock:16:8}))
      curl -s -G --data-urlencode "platform=$platformName" --data-urlencode "jormver=$jormVersion" "https://api.pooltool.io/v0/sharemytip?poolid=${POOL_ID}&userid=$(cat $POOLTOOL_UID_FILE)&genesispref=${GENESIS}&mytip=${lBH1}&lasthash=${lastBlockHash}&lastpool=${lastPoolID}&lastparent=${lastParent}&lastslot=${lastSlot}&lastepoch=${lastEpoch}" > $pooltoolf 2>/dev/null
      echom 4 "Last Pooltool response: Success: $(cat $pooltoolf | jq -r .success) MaxHeight: $(cat $pooltoolf | jq -r .pooltoolmax)"
      j=1
    fi
  fi
  sleep $(($slotDuration/2))
done
