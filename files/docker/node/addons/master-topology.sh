#!/bin/bash

dig relays-new.cardano-mainnet.iohk.io | grep "relays-new.cardano-mainnet.iohk.io." | awk '{ print $5 }' > /tmp/iohk.list

for i in $(cat /tmp/iohk.list )
do
sudo tcpping -x 1 $i 3001 | grep ms | awk '{print $9,$7}' >> /tmp/tcpping.list
done

cat /tmp/tcpping.list | sort -n | grep -v "ms" | head -n 6 | cut -d "(" -f 2 | cut -d ")" -f 1   > /tmp/fastest.list
rm /tmp/tcpping.list
AADD1=$(sed -n 1p /tmp/fastest.list)
AADD2=$(sed -n 2p /tmp/fastest.list)
AADD3=$(sed -n 3p /tmp/fastest.list)
AADD4=$(sed -n 4p /tmp/fastest.list)
AADD5=$(sed -n 5p /tmp/fastest.list)
AADD6=$(sed -n 6p /tmp/fastest.list)
cat <<EOF > /opt/cardano/cnode/priv/files/mainnet-master.json
{
  "Producers": [
    {
      "addr": "relays-new.cardano-mainnet.iohk.io",
      "port": 3001,
      "valency": 2
    },
    {
      "operator": "IOHK1",
      "addr": "$AADD1",
      "port": 3001,
      "valency": 1
    },
    {
      "operator": "IOHK2",
      "addr": "$AADD2",
      "port": 3001,
      "valency": 1
    },
    {
      "operator": "IOHK3",
      "addr": "$AADD3",
      "port": 3001,
      "valency": 1
    },
    {
      "operator": "IOHK4",
      "addr": "$AADD4",
      "port": 3001,
      "valency": 1
    },
    {
      "operator": "IOHK5",
      "addr": "$AADD5",
      "port": 3001,
      "valency": 1
    },
    {
      "operator": "IOHK6",
      "addr": "$AADD6",
      "port": 3001,
      "valency": 1
    },
    {
      "operator": "R01",
      "addr": "78.47.99.41",
      "port": 6000,
      "valency": 1
    },
    {
      "operator": "R02",
      "addr": "168.119.51.182",
      "port": 6000,
      "valency": 1
    },
    {
      "operator": "R03",
      "addr": "95.216.207.178",
      "port": 6000,
      "valency": 1
    }
  ]
}
EOF
rm /tmp/fastest.list;
