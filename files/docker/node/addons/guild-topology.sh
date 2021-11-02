#!/usr/bin/env bash
 
export CNODE_HOME=/opt/cardano/cnode

curl -s -k -o /tmp/guild_topology2.json "https://api.clio.one/htopology/v1/fetch/?max=20"

cat /tmp/guild_topology2.json | awk '{print $3,$5}' | tail -n +2 | sed s/"\","//g  | sed s/"\""//g | sed s/","//g | grep -v [a-z] >  /tmp/guild_list1              

# TCPPING metrics disabled
#IFS=$'\n'; for i in $(cat /tmp/guild_list1 ); do tcpping -x 1 $i | grep ms | awk '{print $9,$7}' >> /tmp/guild_list2 ; done
#cat /tmp/guild_list2 | sort -n | grep -v "ms" | head -n 8 | cut -d "(" -f 2 | cut -d ")" -f 1   > /tmp/fastest_guild.list
#IFS=$'\n'; for i in $(cat /tmp/fastest_guild.list); do  cat /tmp/guild_list1 | grep "$i" >> /tmp/guild_list3; done


GUILD1=$(sed -n 1p /tmp/guild_list1 | awk '{print $1}')
GUILD1PORT=$(sed -n 1p /tmp/guild_list1 | awk '{print $2}')
GUILD2=$(sed -n 2p /tmp/guild_list1 | awk '{print $1}')
GUILD2PORT=$(sed -n 2p /tmp/guild_list1 | awk '{print $2}')
GUILD3=$(sed -n 3p /tmp/guild_list1 | awk '{print $1}')
GUILD3PORT=$(sed -n 3p /tmp/guild_list1 | awk '{print $2}')
GUILD4=$(sed -n 4p /tmp/guild_list1 | awk '{print $1}')
GUILD4PORT=$(sed -n 4p /tmp/guild_list1 | awk '{print $2}')
GUILD5=$(sed -n 5p /tmp/guild_list1 | awk '{print $1}')
GUILD5PORT=$(sed -n 5p /tmp/guild_list1 | awk '{print $2}')
GUILD6=$(sed -n 6p /tmp/guild_list1 | awk '{print $1}')
GUILD6PORT=$(sed -n 6p /tmp/guild_list1 | awk '{print $2}')
GUILD7=$(sed -n 7p /tmp/guild_list1 | awk '{print $1}')
GUILD7PORT=$(sed -n 7p /tmp/guild_list1 | awk '{print $2}')
GUILD8=$(sed -n 8p /tmp/guild_list1 | awk '{print $1}')
GUILD8PORT=$(sed -n 8p /tmp/guild_list1 | awk '{print $2}')

cat <<EOF > $CNODE_HOME/files/guildnet-topology.json
{ "resultcode": "201", "networkMagic": "764824073", "ipType":4, "Producers": [
  { "addr": "relays-new.cardano-mainnet.iohk.io", "port": 3001, "valency": 2, "distance":10 },
  { "addr": "$GUILD1", "port": $GUILD1PORT, "valency": 1, "distance":10 },
  { "addr": "$GUILD2", "port": $GUILD2PORT, "valency": 1, "distance":10 },
  { "addr": "$GUILD3", "port": $GUILD3PORT, "valency": 1, "distance":10 },
  { "addr": "$GUILD4", "port": $GUILD4PORT, "valency": 1, "distance":10 },
  { "addr": "$GUILD5", "port": $GUILD5PORT, "valency": 1, "distance":10 },
  { "addr": "$GUILD6", "port": $GUILD6PORT, "valency": 1, "distance":10 },
  { "addr": "$GUILD7", "port": $GUILD7PORT, "valency": 1, "distance":10 },
  { "addr": "$GUILD8", "port": $GUILD8PORT, "valency": 1, "distance":10 }
] }
EOF

rm  /tmp/fastest_guild.list && rm /tmp/guild_list*
