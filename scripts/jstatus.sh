#!/bin/bash

# Author: Redoracle
# Pool: Stakelovelace.io
# TG: @redoracle
# Website: https://stakelovelace.io/tools/jstatus-watchdog/
#
# To keep logs of this WatchDog tool please use it as described below.
# Usage: ./jstatus.sh 
#
#
# How the fork/stuck check works:
# The script will retrieve  the last block hash elaborated by the node (jcli) and query the ITN IOHK eplorer to very the block hash  
# In addition the node BlockHihgt is updated on PoolTool.io and simultaneosly using the return value and second reference before 
# starting evaluating the Recovery Restart function.
#
# When exported the MY_POOL_ID variable, your pool's stats (rewards and stake) will show up on the screen 
#
# Do not forget to customize the RECOVERY_RESTART() function in order to implement your own recovery procedure.
#
# Featuers:
#              - PoolTool sendtips.sh functions integrated if ENV vars are declared.  
#              - Fork/Sanity Check (by simultaneolsy checking PoolTool and ShellyExplorer)
#              - Node Stuck 
#                       1) by setting max block heghit difference: "Block_diff" (default 50)
#                       2) by setting FLATCYCLE: period which will be considered before triggering RECOVERY RESTART procedure
#              - IM settings and samples for Gotify and Telegram (thanks to @Gufmar)
#              - Jormugandr Storage Auto Backup (only when the node is healthy)
#
#
# Notes: the msg " HASH NOT IN ESPLORER" could appear in 3 different situations:
#
#           - 1) The HAST is not yet in Shelly Exporer, not in sync (usually after few minutes the alert reset because the scripts 
#                retries and finds it)
#           - 2) Shelly Exporer Webserver is not responding (usually after few minutes the alert reset because the scripts retries 
#                and finds it)
#           - 3) The HAST is not yet in Shelly Exporer and never will be because your node is on a fork, for making sure we do not 
#                get False Positive we also check PoolTool - Very Useful Tool -.
#
#   
#85.25.105.92
# Disclaimers:
#               1)   -->!!    USE THIS SCRIPT AT YOUR OWN RISK. IT IS YOUR OWN RESPONSABILITY TO MONITOR YOUR NODE!    !!<--
#               2)                                  DO YOUR OWN TUNING --> 
#       Each node might need proper fine tunes of the Global variable declared under the "## Configuration Parameters" section.
#               3)   -->!!    USE THIS SCRIPT AT YOUR OWN RISK. IT IS YOUR OWN RESPONSABILITY TO MONITOR YOUR NODE!    !!<--
#
# Contributors: @Cardano_Staking_Pools_Alliance SPAI
#
## Shelly Explorer:
# https://explorer.incentivized-testnet.iohkdev.io/explorer/
# 
## Configuration Parameters 
#
## Rewards directory dump
#export JORMUNGANDR_REWARD_DUMP_DIRECTORY=/datak/pool/Stakelovelace/Rewards

## ITN Genesis
GENESISHASH="8e4d2a343f3dcf9330ad9035b3e8d168e6728904262f2c434a4f8f934ec7b676"

## PoolTool Configuration
THIS_GENESIS="8e4d2a343f3dcf93"                     # We only actually look at the first 7 characters of the ITN genesis

#export MY_POOL_ID="YOUR-POOL-ID"                   # Your Pool public ID - IMPORTANT FOR POOL STATS!
#export MY_USER_ID="YOUR-POOLTOOL-ID"               # on pooltool website get this from your account profile page

MENU_POOL=yes        # Disabled by default 

ALERT_MINIMUM=1      # minimum test loops pefore pager alert

## Cycles Time frequency in seconds:
#
FREQ=60                 # Normal Operation Refresh Frequency in seconds

FORK_FREQ=60            # Forck Check - Warning Mode Refresh Frequency in seconds between checks. after 13 consecutive failed attempts to check 
                        # the last block hash the script will try to do the recovery steps if any. See RECOVERY_RESTART().

RECOVERY_CYCLES=3       # How many times will the test cycle (Explorer Website check  + PoolTool check) with consecutive errors
                        # the script will try to do the recovery steps if any. See RECOVERY_RESTART()

FLATCYCLES=1            # Every Cycle FREQ lastblockheight will be checked and if it stays the same for FLATCYCLES times, 
                        # than the Monster will be Unleashed!  

## Block difference checks for stucked nodes
#
Block_diff=10  # Block_diff is a isolated check which alone will trigger 1 of 13 warning alerts befor calling the function RESTART_RECOVERY - Explorer will be out of the checks chain
Block_delay=10  # Block_delay is part of the double check algorithm with the comparison of the shellyExplorer (the combination of 1 Hash not found and Lastblock heigh < 20 blocks trigger 1 of 13 consecutives alerts before triggering the recovery)

## Log PATH
#
LOG_DIRECTORY="/tmp";

## BACKUP
#JTMP="/datak/jormungandr-storage";                  # Jormugandr Storage PATH (must match your storage settings PATH in your node-config.yaml)
                                                    # If set it will enable automatic backup 
JTMPB="/datak/jormungandr-storage_backup"           # Backup destination

BACKUPCYCLES=5                                     # Backup window  FREQ x BACKUPCYCLES = trigger backup procedure

## Telegram Message API 
#
# 1) Talk with @BotFather and a create a new bot with the command "/newbot" follow the procedure and keep notes of your BotToken
# 2) Then invite @Markdown @RawDataBot and also get the "chat_id"
#    This is an individual chat-ID between the bot and this TG-user the bot is allowed to respond, when the user send a first message.
# 3) write some messages within your botchat group and then run the following command:
# 4) curl -s https://api.telegram.org/bot${TG_BotToken}/getUpdates | jq .
#    the returned JSON contains the chat-ID from the last message the bot received.
# 4b) or get directly the chat_id:
#    curl -s https://api.telegram.org/bot${TG_BotToken}/getUpdates | jq . | grep -A1 chat | grep -m 1 id | awk '{print $2}' | cut -d "," -f1
## TG Settings:
#TG_BotToken="xxxxxxxxx:xxxxxxxxxxxx-xxxxxxxxxxxxxxxxxxxxxx"
#TG_ChatId="xxxxxxxxx"
#TG_URL="https://api.telegram.org/bot${TG_BotToken}/sendMessage?chat_id=${TG_ChatId}&parse_mode=Markdown"

## Clolors palette
#
BOLD="\e[1;37m"; GREEN="\e[1;32m"; RED="\e[1;31m"; ORANGE="\e[33;5m"; NC="\e[0m"; CYAN="\e[0;36m"; LGRAY1="\e[1;37m"; LGRAY="\e[2;37m"; BHEIGHT="\e[1;32m";
REW="\e[1;93m"; POOLT="\e[1;44m"; LGREEN="\e[0;32m"; DELGC="\e[1;45m";

## Main Init
#
shopt -s expand_aliases
alias CLI="$(which jcli) rest v0"
alias PCLI="$(which jcli)"
FIRSTSTART="1";

VERSION=$(PCLI -V 2>/dev/null | awk '{ print $2 }' );
JVERSION="J-Ver: $BOLD$VERSION$NC";

clear;
echo -e "\\t\\t$BOLD--   jstatus WatchDog   --$NC";
echo -e "\\t\\t$LGRAY1       v1.2.0   2020 $NC\\n\\n";
echo -e "\\t\\t$LGRAY1 Loading... $JVERSION $NC\\n\\n";

[ -f CLI ] && [ -f jcli ] && CLI="./jcli"
[ -z ${JORMUNGANDR_RESTAPI_URL} ] && echo -e "[ERROR] - you must set the shell variable \$JORMUNGANDR_RESTAPI_URL, \\ncheck your node config for the rest: listen_address to identify the URL, \\neg: export JORMUNGANDR_RESTAPI_URL=http://127.0.0.1:3101/api" && exit 1
[ -z ${MY_USER_ID} ] && echo -e "[WARN] - PoolTool parameters not set \\neg: export MY_POOL_ID=xxxxxxxxxxx \neg: export MY_USER_ID=xxxx-xxxxx-xx" && PoolTSUB="00000";


#Bootstrapping
QUERY=$(CLI  node stats get > /tmp/testBoot 2>/dev/null; QUERYRES=$?;);
BOOTQ=$(grep Bootstr /tmp/testBoot; BOOTQR=$?; )
until [[ $BOOTQR -eq 0 ]]; 
do
    sleep 2;
    QUERY=$(CLI  node stats get > /tmp/testBoot; QUERYRES=$?;);
    BOOTQ=$(grep Bootstr /tmp/testBoot; BOOTQR=$?; );
    clear;
    echo -e "\\n\\n\\t\\t\\t$BOLD - Still Bootstrapping - $NC";
done

## Functions
POOLTOOL_S()
{
if [[ $PoolTSUB == "00000" ]];
then
    BHEIGHT="\e[1;32m";
    PTSUBMISSION=" ";
elif [ "$lastBlockHeight" != "" ]; 
    then
    PoolToolURL="https://api.pooltool.io/v0/sharemytip?poolid=$MY_POOL_ID&userid=$MY_USER_ID&genesispref=$THIS_GENESIS&mytip=$lastBlockHeight&lasthash=$lastBlockHash&lastpool=$lastPoolID&platform=jstatus";
    PoolToolHeight=$(curl -s -G $PoolToolURL | jq -r .pooltoolmax );
    PTSUBMISSION=$(echo "-> $PoolToolHeight <-");
    PoolToolWinLossURL="https://pooltool.s3-us-west-2.amazonaws.com/8e4d2a3/pools/$MY_POOL_ID/byepoch/$lastBlockDateSlot/winloss.json";
    PoolToolWinLoss=$(curl -s -G -o $LOG_DIRECTORY/$lastBlockDateSlot.winloss.json $PoolToolWinLossURL);
    PoolToolWinLossCheck=$(grep -E "w\":" $LOG_DIRECTORY/$lastBlockDateSlot.winloss.json; EMTYWIN=$?;);
    if [[ "$EMTYWIN" -eq 0 ]];
    then
        WIN=$(jq -r .w $LOG_DIRECTORY/$lastBlockDateSlot.winloss.json );
        LOSS=$(jq -r .l $LOG_DIRECTORY/$lastBlockDateSlot.winloss.json );
        PRINTWL="- MLS Won:$GREEN$WIN$NC Lost:$LGREEN$LOSS$NC ";
    else
        PRINTWL="";
    fi
    #Delegtor List
    #curl -s -o $LOG_DIRECTORY/$lastBlockDateSlot.delegators.json https://pooltool.s3-us-west-2.amazonaws.com/8e4d2a3/pools/$MY_POOL_ID/delegators.json
    #Rewards
    #curl -s -o $LOG_DIRECTORY/$lastBlockDateSlot.rewards_EPOCH.json https://pooltool.s3-us-west-2.amazonaws.com/8e4d2a3/pools/$MY_POOL_ID/rewards_EPOCH.json
    #Stake
    curl -s -o $LOG_DIRECTORY/$lastBlockDateSlot.currentstakers.json https://pooltool.s3-us-west-2.amazonaws.com/8e4d2a3/pools/$MY_POOL_ID/currentstakers.json
fi
}

POOLTOOL()
{
PoolToolStats2=$(curl -s -o $LOG_DIRECTORY/pooltool_stats.json https://pooltool.s3-us-west-2.amazonaws.com/stats/stats.json);
PoolT_min=$(jq .min $LOG_DIRECTORY/pooltool_stats.json);
PoolT_syncd=$(jq .syncd $LOG_DIRECTORY/pooltool_stats.json );
PoolT_sample=$(jq .samples $LOG_DIRECTORY/pooltool_stats.json);
PoolT_max=$(jq .majoritymax $LOG_DIRECTORY/pooltool_stats.json);
PoolT_sec=$(jq .distribution $LOG_DIRECTORY/pooltool_stats.json | sort -nr -t: -k 2 | grep -v $PoolT_max |head -n 1 |cut -d "\"" -f 2);

POOLTOOLSTAS="PoolTHeight:\\t$POOLT-> $PoolT_max >> $PoolT_sec - ($PoolT_syncd/$PoolT_sample)$NC";

if [ "$lastBlockHeight" -lt $(($PoolT_max - $Block_delay)) 2> /dev/null ]; 
then
    BHEIGHT="\e[1;31m";
else
    BHEIGHT="\e[1;32m";
fi
}

INIT_JSTATS()
{
#sleep 5;
DATE=$(date);
ORA=$(date +"%H");
HOSTN=$(hostname);
DAY=$(date +"%d");
NEWORA="10#$ORA"
let NEXT_ORA1=NEWORA+1;
if [[ "$NEXT_ORA1" -eq "24" ]]; then NEXT_ORA2="00"; NEXT_ORA=$(printf %02d $NEXT_ORA2); let DAY2=DAY+1; else NEXT_ORA=$(printf %02d $NEXT_ORA1); DAY2="$DAY"; fi
let PREV_ORA1=NEWORA-1;
PREV_ORA=$(printf %02d $PREV_ORA1);
TMPF="$LOG_DIRECTORY/stats.json";
DELEGJ=$(CLI stake get | grep "\- \-"| wc -l);
# API STUCK RECOVERY CYCLE
QUERY=$(CLI  node stats get --output-format json > $TMPF 2>/dev/null; QUERYRES=$?;);
BOOTQ=$(grep Bootstrap $TMPF; BOOTQR=$?; )
if [[ $QUERYRES -gt 0 ]]; then
    sleep 15;
    QUERY2=$(CLI  node stats get --output-format json > $TMPF 2>/dev/null; QUERYRES2=$?;);
elif [[ $QUERYRES2 -gt 0 ]]; then
    sleep 15;
    QUERY3=$(CLI  node stats get --output-format json > $TMPF 2>/dev/null; QUERYRES3=$?;);
elif [[ $QUERYRES3 -gt 0 ]]; then
    STATUS="REST API STUCK";
    PAGER;
    RECOVERY_RESTART;
else

until [[ $BOOTQR -eq 0 ]]; 
do
    sleep 1;
    QUERY=$(CLI  node stats get --output-format json > $TMPF 2>/dev/null; QUERYRES=$?;);
    BOOTQ=$(grep Bootstrapping $TMPF; BOOTQR=$?; )
    STATUS="$BOLD - Still Bootstrapping - $NC";
    PRINT_SCREEN;
done
peerAvailableCnt=$(jq -r .peerAvailableCnt $TMPF 2>/dev/null);
peerQuarantinedCnt=$(jq -r .peerQuarantinedCnt $TMPF 2>/dev/null);
peerUnreachableCnt=$(jq -r .peerUnreachableCnt $TMPF 2>/dev/null);
lastBlockDateSlot=$(jq -r .lastBlockDate $TMPF | cut -d "." -f 1);
lastBlockDateSlotFull=$(jq -r .lastBlockDate $TMPF 2>/dev/null)
blockRecvCnt=$(jq -r .blockRecvCnt $TMPF 2>/dev/null);
lastBlockHeight=$(jq -r .lastBlockHeight $TMPF 2>/dev/null);
uptime=$(jq -r .uptime $TMPF 2>/dev/null);
lastBlockTx=$(jq -r .lastBlockTx $TMPF 2>/dev/null);
txRecvCnt=$(jq -r .txRecvCnt $TMPF 2>/dev/null);
nodesEstablished=$(CLI network stats get --output-format json 2>/dev/null | jq '. | length' );
Quarantined=$(curl -s $JORMUNGANDR_RESTAPI_URL/v0/network/p2p/quarantined 2>/dev/null  | jq '.' | grep addr | sort | uniq | wc -l)
Quarantined_non_public=$(curl -s $JORMUNGANDR_RESTAPI_URL/v0/network/p2p/non_public 2>/dev/null  | jq '.' | grep addr | sort | uniq | wc -l)
LAST_HASH=$(jq -r .lastBlockHash $TMPF 2>/dev/null);
lastBlockHash=$LAST_HASH;
lastPoolID=$(CLI block ${LAST_HASH} get 2>/dev/null | cut -c169-232);

POOLTOOL;

if [ $MY_POOL_ID ]; 
    then
    LAST_EPOCH_POOL=$(CLI stake-pool get $MY_POOL_ID > $LOG_DIRECTORY/$lastBlockDateSlot.poolstats_01 2>/dev/null);    
    LAST_EPOCH_POOL_REWARDS=$(grep value_taxed $LOG_DIRECTORY/$lastBlockDateSlot.poolstats_01 | awk '{print $2}' | awk '{print $1/1000000}' | cut -d "." -f 1 );
    LAST_EPOCH_POOL_DEL_REWARDS=$(grep value_for_stakers $LOG_DIRECTORY/$lastBlockDateSlot.poolstats_01 | awk '{print $2}' | awk '{print $1/1000000}' | cut -d "." -f 1 );
    POOL_DELEGATED_STAKEQ=$(grep total_stake $LOG_DIRECTORY/$lastBlockDateSlot.poolstats_01 | awk '{print $2}' | awk '{print $1/1000000000}' | cut -d "." -f 1 );
    POOL_DELEGATED_STAKE="Stake(K):\\t$REW$POOL_DELEGATED_STAKEQ$NC";
    LASTPOOLREWARDS="PoolRewards:\\t$REW$LAST_EPOCH_POOL_REWARDS$NC";
    LASTREWARDS="DelegRewards:\\t$REW$LAST_EPOCH_POOL_DEL_REWARDS$NC";

    POOLINFO="-> $POOL_DELEGATED_STAKE\\t- $LASTREWARDS\\t- $LASTPOOLREWARDS\\n\\n-> Made:$GREEN$CONCHAIN$NC/$LGREEN$BLOCKS_MADE$NC $PRINTWL- Rejected:$RED$BLOCKS_REJECTED$NC - Slots:$ORANGE$SLOTS$NC/$TOTS - Planned(b/h):$BOLD$NEXT_SLOTS$NC\\n";
    else
    POOLINFO="";
fi

curl -s 'https://explorer.incentivized-testnet.iohkdev.io/explorer/graphql' -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:71.0) Gecko/20100101 Firefox/71.0' -H 'Accept: */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H "Referer: https://shelleyexplorer.cardano.org/en/block/$LAST_HASH/" -H 'Content-Type: application/json' -H 'Origin: https://shelleyexplorer.cardano.org' -H 'DNT: 1' -H 'Connection: keep-alive' -H 'TE: Trailers' --data-binary "{\"query\":\"\n    query {\n      stakePool (id:\\\"$MY_POOL_ID\\\") {\n        blocks (last: 10000) {\n          totalCount\n          edges {\n            cursor\n            node {\n              \n  id\n  date {\n    slot\n    epoch {\n      \n  id\n  firstBlock {\n    id\n  }\n  lastBlock {\n    id\n  }\n  totalBlocks\n\n    }\n  }\n            }\n          }\n        }\n      }\n    }\n  \"}" | jq -r . > $LOG_DIRECTORY/onchainblocks.json 2>/dev/null;                       
QRESU=$?;

if [[ $QRESU -gt 0 ]]; then
    echo -e "\\t\\t\\t $BOLD IOHK Explorer not responding ... \\n\\t\\t\\t\\t .. or out of sync (forked!)$NC";
fi
#Total
TONCHAIN=$(grep -A1 node $LOG_DIRECTORY/onchainblocks.json | grep id  | wc -l);
#Current epoch
CONCHAIN=$(grep -A1 epoch $LOG_DIRECTORY/onchainblocks.json| grep $lastBlockDateSlot  | wc -l);

LEADERS="$LOG_DIRECTORY/$lastBlockDateSlot.leaders_logs.log";   # PATH of the temporary leaders logs from jcli for collecting stats
LEADERS_QUERY=$(CLI leaders logs get > $LEADERS 2>/dev/null);
LOGMADE="$LOG_DIRECTORY/$lastBlockDateSlot.leaders_made.log";
LOGHISTORY="$LOG_DIRECTORY/$lastBlockDateSlot.leaders_logs.1";
REJLOGS="$LOG_DIRECTORY/$lastBlockDateSlot.leaders_rej_logs";
REJLOGSU="$LOG_DIRECTORY/$lastBlockDateSlot.leaders_rej_uniq_logs";
ESLEADERS="$LOG_DIRECTORY/$lastBlockDateSlot.EpochSlots.log";

if [ -f $ESLEADERS ]
then
    TOTS=$(grep scheduled_at_date $ESLEADERS | grep "$lastBlockDateSlot\." | wc -l);
else
    EPOCHTOTSLOTS=$(CLI leaders logs get 2>/dev/null| grep -B5 -A1 Pending > $ESLEADERS );
    TOTS=$(grep scheduled_at_date $ESLEADERS | grep "$lastBlockDateSlot\." | wc -l);
fi

SLOTS=$(grep -B2 Pending $LEADERS | grep -A1 scheduled_at_date | grep scheduled_at_time | wc -l);
NEXT_SLOTS=$(grep -B2 Pending $LEADERS | grep -A1 scheduled_at_date | grep scheduled_at_time | grep $DAY'T'$ORA | wc -l);
NEXT_SLOTS_LIST=$(grep -B2 Pending $LEADERS | grep -A1 scheduled_at_date | grep scheduled_at_time | grep $DAY'T'$ORA | awk '{print $2}'| cut -d "T" -f 2|cut -d "+" -f 1| sort);
FUTUR_SLOTS=$(grep scheduled_at_time  $ESLEADERS | grep $DAY2'T'$NEXT_ORA | awk '{print $2}'| cut -d "T" -f 2|cut -d "+" -f 1| sort | head -n 2);
grep -A1 -B3 Block $LEADERS | grep -E "scheduled_at_time|scheduled_at_date|block" | sed ':r;$!{N;br};s/\n  scheduled_at_time:/ scheduled_at_time:/g' | sed ':r;$!{N;br};s/\n      block/ block/g' | awk '{print $4,$2,$6}' | cut -d "T" -f 2 | sed s/\"//g >> $LOGHISTORY;
BLOCKS_MADE2=$(cat $LOGHISTORY | sort -n | uniq  > $LOGMADE );
LAST_BLOCKH=$(grep "$lastBlockDateSlot\." $LOGMADE | grep -E "^$PREV_ORA\:|^$ORA\:" 2>/dev/null | tail -n 1 | sed s/+00:00//g | awk '{ print $3 }');
BLOCKS_MADE=$(grep "$lastBlockDateSlot\." $LOGMADE | wc -l);
PREV_SLOTS=$(grep "$lastBlockDateSlot\." $LOGMADE | grep -E "^$PREV_ORA\:|^$ORA\:" 2>/dev/null | tail -n 2 | sed s/+00:00//g );
watch_node=$(netstat -anl  | grep tcp | grep EST |  awk '{ print $5 }' | cut -d ':' -f 1 | sort | uniq | wc -l);
BLOCKS_REJECTED1=$(grep -B3 Rejected $LEADERS | grep -A1 "$lastBlockDateSlot\."| grep scheduled_at_time >> $REJLOGS);
BLOCKS_REJECTED2=$(cat $REJLOGS | sort -nr | uniq > $REJLOGSU );
BLOCKS_REJECTED=$(cat $REJLOGSU | wc -l );
REASON_REJECTED=$(grep -A1 Rejected $LEADERS);
fi
}

MENUSTAST()
{
#Forkers
curl -s -o $LOG_DIRECTORY/$lastBlockDateSlot.forkers.json https://pooltool.s3-us-west-2.amazonaws.com/stats/forkers.json
#Heights Reported
curl -s -o $LOG_DIRECTORY/$lastBlockDateSlot.heights.json https://pooltool.s3-us-west-2.amazonaws.com/stats/heights.json
#Realttime
#curl -s -o $LOG_DIRECTORY/$lastBlockDateSlot.syncd.json https://pooltool.s3-us-west-2.amazonaws.com/8e4d2a3/stats/syncd.json
#OverAll
curl -s -o $LOG_DIRECTORY/$lastBlockDateSlot.epochstats.json https://pooltool.s3-us-west-2.amazonaws.com/8e4d2a3/epochstats.json
}

MENU()
{
MENUSTAST;
show_menus; 
read_options;
}

PRINT_SCREEN()
{
clear;
echo -e "-> $DATE  $JVERSION\\t$STATUS";
echo -e "-> HOST:$BOLD$HOSTN$NC  Blocks:$BOLD$TONCHAIN$NC  Epoch:$BOLD$lastBlockDateSlotFull$NC  Uptime:$BOLD$uptime$NC $PBKMB";
echo -e " ";
echo -e "-> RecvCnt:\\t$LGRAY$blockRecvCnt$NC \\t- BlockHeight:\\t$BHEIGHT-> $lastBlockHeight $PTSUBMISSION$NC";
echo -e "-> BlockTx:\\t$LGRAY$lastBlockTx$NC \\t- $POOLTOOLSTAS";
if [[ $peerUnreachableCnt ]] 
then
echo -e "-> PUnreach:\\t$RED$peerUnreachableCnt$NC \\t- PAvail:\\t$BOLD$peerAvailableCnt$NC \\t- PQuarantined:\\t$ORANGE$peerQuarantinedCnt$NC";
echo -e "-> UniqIP:\\t$CYAN$watch_node$NC \\t- Established:\\t$BOLD$nodesEstablished$NC \\t- Quarantined:\\t$ORANGE$Quarantined$NC";
else
echo -e "-> UniqIP:\\t$CYAN$watch_node$NC \\t- Established:\\t$BOLD$nodesEstablished$NC \\t- Quarantined:\\t$ORANGE$Quarantined$NC";
fi
if [ $MY_POOL_ID ]; 
then
echo -e "$POOLINFO";
echo -e "-> Last Tx Hash:  $BOLD$LAST_HASH$NC";
echo -e "-> Leader Slots:";
echo -e "$PREV_SLOTS";
if [[ "$NEXT_SLOTS" > 0 ]]
then
echo -e "$BOLD$NEXT_SLOTS_LIST$NC";
fi
echo -e "$ORANGE$FUTUR_SLOTS$NC";
echo -e "$ORANGE$REASON_REJECTED$NC";
else
echo -e "\\n";
echo -e "-> Last Tx Hash:  $BOLD$LAST_HASH$NC";
fi
echo "$DATE, $VERSION, $HOSTN, $TONCHAIN, $lastBlockDateSlotFull, $uptime, $lastBlockHeight, $peerUnreachableCnt, $peerAvailableCnt, $peerQuarantinedCnt, $watch_node, $nodesEstablished, $Quarantined, $LAST_EPOCH_POOL_REWARDS, $LAST_EPOCH_POOL_DEL_REWARDS, $POOL_DELEGATED_STAKEQ, $CONCHAIN, $BLOCKS_MADE, $BLOCKS_REJECTED, $SLOTS, $TOTS, $BLOCKS_REJECTED, $WIN, $LOSS" >> $LOG_DIRECTORY/$lastBlockDateSlot.jstatus.log;
if [[ "$MENU_POOL" == "no" ]]; then
sleep $FREQ;
else
MENU;
fi
}

RECOVERY_RESTART()
{
    STATUS="$RED--> We're ... Restarting! <--$NC";
    #TGAUE=$(curl -s -X POST $TG_URL -d text="$HOSTN Recovery Restart %0AFLATLINERSCOUNTER:$FLATLINERSCOUNTER %0ATRY:$TRY %0AHASH: $LAST_HASH %0APOOLTHEIGHT: $PoolT_max %0APOOLINFO DS: $POOL_DELEGATED_STAKEQ LR: $LAST_EPOCH_POOL_REWARDS");
    #jshutdown=$(CLI shutdown get);
    sleep 2;
    #CLEANDB=$(rm -rf $JTMP);
    #jshutdown2=$(ps max | grep jorm | grep config | awk '{print $1}');
    #jshutdown3=$(kill -9 $jshutdown2 2&> /dev/null );
    #jshutdown4=$(killall ~/jormungandr/jormungandr 2&> /dev/null );
    #CLEANDB=$(rm -rf $JTMP);
    sleep 1;
    #RECOVERSTORAGE=$(cp -rf $JTMPB $JTMP);
    #MVLOG=$(mv $LOG_DIRECTORY/$HOSTN.log /datak/$HOSTN.log.bk);
    #RECOVERY=$(echo -e "\\t\\t $RED--> Recovery in course please wait around 10 minutes$NC");
    #GHASH=$(cat /datak/genesis-hash.txt); 
    #START_JORGP=$(/root/jormungandr/jormungandr --config /datak/node-config.yaml --secret /datak/pool/Stakelovelace/secret.yaml --genesis-block-hash $GHASH &>> $LOG_DIRECTORY/$HOSTN.log &);
}

PAGER()
{
    #echo -e "\\n \\t\\t\\t$RED-->  Pager Warning Alert sent!   <--$NC";
    #STATUS="$RED-->  Pager Warning Alert sent! $NC";
    ##Telegram
    TGAUE=$(curl -s -X POST $TG_URL -d text="$HOSTN $STATUS %0ATRY:$TRY FLATLINERSCOUNTER:$FLATLINERSCOUNTER BlockHeight: $lastBlockHeight %0AHASH:[$LAST_HASH](https://explorer.incentivized-testnet.iohkdev.io/tx/$LAST_HASH) %0APOOLTHEIGHT: $PoolT_max %0APOOLINFO DS: $POOL_DELEGATED_STAKEQ LR: $LAST_EPOCH_POOL_REWARDS");
    ##Gotify
    AUE=$(curl -s -X POST "http://172.13.0.4/message?token=Ap59j48LrTeyvQx" -F "title=$HOSTN Potential Fork" -F "message=TRY:$TRY -> HASH:$LAST_HASH PTH:$PoolT_max DS:$POOL_DELEGATED_STAKEQ LR:$LAST_EPOCH_POOL_REWARDS" -F "priority=$TRY");
}

PAGER_BLOCK_MADE()
{
    if [ "$FIRSTSTART" -eq "1" ]; then
        FIRSTSTART=0;
    else
        #echo -e "\\t\\t\\t$REW-->  New block Made!  <--$NC";
        STATUS="-->  New block Made!  <--   👍";
        ##Telegram
        curl -s -X POST $TG_URL -d text="$HOSTN $STATUS %0AN: $CONCHAIN - $BLOCKS_MADE EpochSlots:$TOTS Remaining:$SLOTS %0AWin:$WIN Lost:$LOSS Storage:$BKMB %0APOOLTHEIGHT: $PoolT_max BlockHeight: $lastBlockHeight %0APOOLINFO: DS: $POOL_DELEGATED_STAKEQ LR: $LAST_EPOCH_POOL_DEL_REWARDS %0ABlock:[$LAST_BLOCKH](https://explorer.incentivized-testnet.iohkdev.io/block/$LAST_BLOCKH)" > /tmp/lasttx.json ;
        #AUE=$(curl -s -X POST "http://172.13.0.4/message?token=Ap59j48LrTeyvQx" -F "title=$HOSTN Block just Made" -F "message=$HOSTN Block just Made N:$BLOCKS_MADE PTH:$PoolT_max DS:$POOL_DELEGATED_STAKEQ LR:$LAST_EPOCH_POOL_REWARDS" -F "priority=5");
        STATUS="$REW-->  New block Made!  <--   👍 $NC";
    fi

}

PAGER_BLOCK_REJ()
{
        #echo -e "\\n \\t\\t\\t$RED-->  New block Rejected!  <--$NC";
        STATUS="$RED-->  New block Rejected!  <--$NC";
        ##Telegram
        #TGAUE=$(curl -s -X POST $TG_URL -d text="$HOSTN Block just Rejected N:$BLOCKS_REJECTED R:$REASON_REJECTED %0APOOLTHEIGHT: $PoolT_max %0APOOLINFO DS: $POOL_DELEGATED_STAKEQ LR: $LAST_EPOCH_POOL_REWARDS");
        ##Gotify
        AUE=$(curl -s -X POST "http://172.13.0.4/message?token=Ap59j48LrTeyvQx" -F "title=HOSTN Block just Rejected" -F "message=$HOSTN Block just Rejected Reason:$REASON_REJECTED POOLTHEIGHT: $PoolT_max" -F "priority=8");
}

EVAL_PAGE_BLOCK()
{
if [ $BLOCKS_REJECTED -gt $BLOCKS_REJECTED_TMP ]; then
    PAGER_BLOCK_REJ;
    BLOCKS_REJECTED_TMP="$BLOCKS_REJECTED";
else
    BLOCKS_REJECTED_TMP="$BLOCKS_REJECTED";
fi
    
if [ $BLOCKS_MADE -gt $BLOCKS_MADE_TMP ]; then
    PAGER_BLOCK_MADE;
    BLOCKS_MADE_TMP="$BLOCKS_MADE";
else
    BLOCKS_MADE_TMP="$BLOCKS_MADE";
fi
}

EXPLORER_CHECK()
{
curl -s 'https://explorer.incentivized-testnet.iohkdev.io/explorer/graphql' -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:71.0) Gecko/20100101 Firefox/71.0' -H 'Accept: */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H "Referer: https://shelleyexplorer.cardano.org/en/block/$LAST_HASH/" -H 'Content-Type: application/json' -H 'Origin: https://shelleyexplorer.cardano.org' -H 'DNT: 1' -H 'Connection: keep-alive' -H 'TE: Trailers' --data "{\"query\":\"\n    query {\n      block (id: \\\"$LAST_HASH\\\") {\n        id\n      }\n    }\n  \"}" | grep "\"block\":{\"id\":\"$LAST_HASH\"" &> $LOG_DIRECTORY/explorer.check.log;
RESU=$?;

if [[ $FLATLINERSCOUNTER -gt 0  ]]; then
    STATUS="$RED- FLATLINER DETECTED! n:$FLATLINERSCOUNTER -$NC";
elif [[ $FLATLINERSCOUNTER -gt 0  &&  $RESU -gt 0 ]]; then
    STATUS="$RED- Hash NOT in Explorer and FLATLINER n:$FLATLINERSCOUNTER -$NC";
elif [ $RESU -gt 0 ]; then
    STATUS="$ORANGE--> Hash NOT in Explorer! $NC";
else
    STATUS="$GREEN --> Looking Good! <--$NC";
fi
}

FLATLINERS_CHECK()
{
    lastBlockHeight=$(jq -r .lastBlockHeight $TMPF);

    if [[ $lastBlockHeight -eq $FLATLINERS && $lastBlockHeight -lt $PoolT_max && $lastBlockHeight != "null" ]];
        then
            let FLATLINERSCOUNTER+=1;
        else 
            FLATLINERS="$lastBlockHeight";
            FLATLINERSCOUNTER=0;
    fi
}

# Customize it with your own backup procedure
STORAGE_BACKUP()
{
if [ $JTMP ] && [ "$BACKUP" -eq "0" ]; then
        BACKUP_RUN_CLEAN=$(rm -rf $JTMPB);
        BACKUP_RUN_COPY=$(cp -rf $JTMP $JTMPB);
        let BACKUP+=1;
        BKMB=$(du -sh $JTMP | awk '{print $1}');
        PBKMB="Storage:$BOLD$BKMB$NC";
        # echo "Backup done!";
    elif  [ "$BACKUP" -gt "$BACKUPCYCLES" ]; then
        BACKUP=0;
        BKMB=$(du -sh $JTMP | awk '{print $1}');
        PBKMB="Storage:$BOLD$BKMB$NC";
        # echo "Backup to be created next cycle";
    else
        let BACKUP+=1;
        BKMB=$(du -sh $JTMP | awk '{print $1}');
        PBKMB="Storage:$BOLD$BKMB$NC";
        # echo "No backup activity";
fi
}

POOLTMENU()
{
HSTATS=$(jq .tips -r $LOG_DIRECTORY/$lastBlockDateSlot.heights.json | grep ":" |cut -d ":" -f 2 | sed s/,//g | sort | uniq -c | sort -k 1 -nr | head -n 15 | sed 's/^/\t/' > $LOG_DIRECTORY/$lastBlockDateSlot.heights.json.log );
FKSTATS=$(jq . -r $LOG_DIRECTORY/$lastBlockDateSlot.forkers.json | grep ":" | grep -v "\{" | cut -d "\"" -f 2 | sort | head -n 15  > $LOG_DIRECTORY/$lastBlockDateSlot.forkers.json.log )
echo -e "\\t\\t${POOLT}-->            PoolTool Statistics            <--${NC}\\n"
echo -e "\\t\\t${BOLD}   Tips Stats\\t - \\tForkers Tips ${NC}\\n";

#IFS=""
:|paste $LOG_DIRECTORY/$lastBlockDateSlot.heights.json.log $LOG_DIRECTORY/$lastBlockDateSlot.forkers.json.log | expand -t 15
echo -e "\\n";
} 

POOLNETW()
{
    OPFI=$(CLI diagnostic get | jq .open_files_limit -r );
    CPUSG=$(CLI diagnostic get | jq .cpu_usage_limit -r );
    echo -e "-> OpenFiles:\\t${BOLD}$OPFI${NC} - CpuUsage: ${ORANGE}$CPUSG${NC} -> Total Nodes:${BOLD}$DELEGJ${NC}";
    echo -e "-> PUnreach:\\t${RED}$peerUnreachableCnt${NC} \\t- PAvail:\\t${BOLD}$peerAvailableCnt${NC} \\t- PQuarantined:\\t${ORANGE}$peerQuarantinedCnt${NC}";
    echo -e "-> UniqIP:\\t${CYAN}$watch_node${NC} \\t- Established:\\t${BOLD}$nodesEstablished${NC} \\t- Quarantined:\\t${ORANGE}$Quarantined${NC}\\n";
    echo -e "\\t\\t${BOLD}Node IDs \\t\\t - \\tNetstat ${NC}\\n";
    NetSTAT=$(netstat -anl  | grep tcp | grep EST |  awk '{ print $5 }' | cut -d ':' -f 1 | sort | uniq -c | sort -k 1 -nr | head -n 15 > /$LOG_DIRECTORY/$lastBlockDateSlot.ipstats.log);
    TOPPoolID=$(CLI network stats get | grep nodeId |  awk '{ print $2 }' | sed s/\"//g | cut -c 13-40 | sort | uniq -c | sort -nr | head -n 15 > /$LOG_DIRECTORY/$lastBlockDateSlot.poolid.log);

#IFS=""
:|paste -d ' - ' /$LOG_DIRECTORY/$lastBlockDateSlot.poolid.log /$LOG_DIRECTORY/$lastBlockDateSlot.ipstats.log
echo -e " ";
}    
POOLOLDER()
{
# Top 10 Older
echo -e "\\n\\t\\t\\t${DELGC}--> Delegators Statistics <--${NC}";
echo -e "\\n\\t${BOLD}Older Delegators (k)\\t - \\tLatest Delegators (k) ${NC}\\n";
jq .[]  $LOG_DIRECTORY/$lastBlockDateSlot.currentstakers.json 2> /dev/null | jq -r '.[] | "\(.epochsstaked)"' 2> /dev/null | sort -nr -k 1 | uniq > $LOG_DIRECTORY/$lastBlockDateSlot.olderholder.lista;
head -n 15 $LOG_DIRECTORY/$lastBlockDateSlot.olderholder.lista > $LOG_DIRECTORY/$lastBlockDateSlot.olderholder.top;
tail -n 15 $LOG_DIRECTORY/$lastBlockDateSlot.olderholder.lista > $LOG_DIRECTORY/$lastBlockDateSlot.youngholder.top;
rm $LOG_DIRECTORY/$lastBlockDateSlot.olderholder.log 2>/dev/null;
rm $LOG_DIRECTORY/$lastBlockDateSlot.youngholder.log 2>/dev/null;

IFS=$'\n'
for i in $(cat $LOG_DIRECTORY/$lastBlockDateSlot.olderholder.top)
do
jq .[]  $LOG_DIRECTORY/$lastBlockDateSlot.currentstakers.json 2> /dev/null| jq -r '.[] | "\(.epochsstaked)\t\(.stake)"' 2> /dev/null | sort -n -k 1 | grep -E "^$i\s" | awk '{ sum += $2; } END { print $1, sum/1000000000; }' "$@" >> $LOG_DIRECTORY/$lastBlockDateSlot.olderholder.log;
done

for j in $(cat $LOG_DIRECTORY/$lastBlockDateSlot.youngholder.top)
do
jq .[]  $LOG_DIRECTORY/$lastBlockDateSlot.currentstakers.json 2> /dev/null| jq -r '.[] | "\(.epochsstaked)\t\(.stake)"' 2> /dev/null | sort -n -k 1 | grep -E "^$j(\d)?\s" | awk '{ sum += $2; } END { print $1, sum/1000000000; }' "$@" >> $LOG_DIRECTORY/$lastBlockDateSlot.youngholder.log;
done

rm $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.young.log 2>/dev/null;
rm $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.older.log 2>/dev/null;
rm $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.older.log1 2>/dev/null;
rm $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.young.log1 2>/dev/null;

for i in $(cat $LOG_DIRECTORY/$lastBlockDateSlot.youngholder.log)
do
    OUT1=$(echo  "$i" |  awk '{printf "%d %.1f", $1, $2}'  |  awk '{printf "%-9s - %11s", $1, $2}');
    echo -e "\t$OUT1\t" >> $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.young.log1;
done

for j in $(cat $LOG_DIRECTORY/$lastBlockDateSlot.olderholder.log)
    do
    OUT2=$(echo  "$j" |  awk '{printf "%d %.1f", $1, $2}'  |  awk '{printf "%-5s - %11s", $1, $2}');
    echo -e "\t$OUT2\t" >> $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.older.log1;
done
Norm1=$(cat $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.young.log1 | sort -n -k 1 | uniq > $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.young.log;)
Norm2=$(cat $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.older.log1 | sort -n -k 1 | uniq > $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.older.log;)
# > $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.log;

#IFS=""
:|paste -d ' - ' $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.older.log $LOG_DIRECTORY/$lastBlockDateSlot.pool.report.young.log
echo -e "\\n";
}

pause(){
  #echo -e "\n";
  read -t 10 -p "Press [Enter] key to continue..." fackEnterKey
}

# function to display menus
show_menus() {
    echo -e "-> ${BOLD}Menu:${NC} (${BOLD}N${NC})etwork - (${BOLD}D${NC})eleg - P(${BOLD}T${NC})ool - (${BOLD}*${NC})Refresh - (${BOLD}REC${NC})overy - (${BOLD}Q${NC})uit \\n";
}

#trap '' SIGINT SIGQUIT SIGTSTP
read_options(){
while true;
do
    local choice
    read -t $FREQ -p "[ N/P/D/T/REC/*/Q ]: " choice
    case $choice in
        N) clear; POOLNETW; pause; break; ;;
        D) clear; POOLOLDER; pause; break;  ;;
        T) clear; POOLTMENU; pause; break; ;;
        REC) clear; echo -e "\\n\\t\\t\\t Pool Restart Recovery Triggered ..."; RECOVERY_RESTART; echo -e "\\n\\t\\t\\t Pool Restarted ... \\n\\t\\t\\t Please wait..  \\n\\t\\t\\t Bootstrapping..."; pause; break; ;;
        R) break; ;;
        Q) exit 0 ;;
        *) echo -e "$ORANGE Loading... $NC"; break; ;;
    esac
done
}

## Reset Variables
BLOCKS_MADE_TMP=0;
BLOCKS_REJECTED_TMP=0;
FLATLINERS=0;
FLATLINERSCOUNTER=0;
TRY=0;
BACKUP=0;
PoolT_max="$Block_diff";

## Main process ##
##################
INIT_JSTATS;
while :
do
    EXPLORER_CHECK;
        if ([ "$RESU" -gt 0 ] && [ "$lastBlockHeight" ] && [[ "$lastBlockHeight" -lt $(($PoolT_max - $Block_delay)) ]]) || [ "$lastBlockHeight" ] && [[ "$lastBlockHeight" -lt $(($PoolT_max - $Block_diff)) ]] || [[ "$FLATLINERSCOUNTER" -gt "$FLATCYCLES" ]];
        then
             echo -e "\\t\\t$BOLD -->  jormungandr is not responding properly ...$NC";
             echo -e "\\t\\t$RED -->  Evaluating Recovery Restart <--$NC";
             #sleep 10;
             until [ $TRY -gt $RECOVERY_CYCLES ]; 
             do
                INIT_JSTATS;
                FLATLINERS_CHECK;
                EXPLORER_CHECK;
                PRINT_SCREEN;
                        if ([ "$RESU" -gt 0 ] && [[ "$lastBlockHeight" -lt $(($PoolT_max - $Block_delay)) ]]) || [[ "$lastBlockHeight" -lt $(($PoolT_max - $Block_diff)) ]] || [[ "$FLATLINERSCOUNTER" -gt "$FLATCYCLES" ]];
                        then
                            sleep 2;
                            STATUS="Try: $RED$TRY$NC/$ORANGE$RECOVERY_CYCLES$NC before recovery restart.";

                                # YOUR Pager Fork msg
                                if [[ "$TRY" -gt "$ALERT_MINIMUM" || "$FLATLINERSCOUNTER" -gt "$ALERT_MINIMUM" ]];
                                then
                                    STATUS="-->  Pager Warning Alert sent!"; PAGER; STATUS="$RED-->  Pager Warning Alert sent! $NC";
                                    EXPLORER_CHECK;
                                    PRINT_SCREEN;
                                    #echo -e "\\n\\t$RED-->  Warning alert sent <--$NC";
                                fi
                                # RECOVERY RESTART CONDITIONS
                                if [[ "$TRY" -eq "$RECOVERY_CYCLES" || "$FLATLINERSCOUNTER" -gt "$FLATCYCLES" ]];
                                then
                                    STATUS="$RED--> Recovering... Please wait... <--$NC";
                                    echo -e "\\n\\t$RED--> Try:$TRY and/or FLATLINERSCOUNTER:$FLATLINERSCOUNTER !!!$NC";
                                    RECOVERY_RESTART;
                                    PRINT_SCREEN;
                                    TRY="$RECOVERY_CYCLES";
                                    let TRY+=1;
                                    FLATLINERSCOUNTER=0;
                                    sleep 10;
                                else
                                    let TRY+=1;
                                fi
                        # Recovery waiting cycle
                            sleep $FORK_FREQ;
                        else
                            #echo -e "\\t\\t-->$GREEN Restart Aborted $NC";
                            STATUS="--> Restart Aborted <--"; PAGER; STATUS="-->$GREEN Restart Aborted <--$NC";
                            PRINT_SCREEN;
                            let TRY="$RECOVERY_CYCLES";
                            let TRY+=1;
                        fi
             done
                #sleep 1;
        else
            TRY=0;
        fi
        INIT_JSTATS;
        POOLTOOL_S;
        FLATLINERS_CHECK;
        EXPLORER_CHECK;
        EVAL_PAGE_BLOCK;
        STORAGE_BACKUP;
        PRINT_SCREEN;
        TRY=0;
        FLATLINERSCOUNTER=0;
done
