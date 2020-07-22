### Create Keys/Address

This script assists you to create a Private key file and generates a corresponding address script for it
``` bash
cd $CNODE_HOME/scripts
./createAddr.sh
# Usage: ./createAddr.sh <Path with name (prefix) for keys to be created>
# Example:
# ./createAddr.sh ~/priv/key_2107
# addr1vyxqqy9ndyvx3l5scgf5j79y6xjdq6rcdrtlxrxgdygl3hqmuw794
# addr1qyxqqy9ndyvx3l5scgf5j79y6xjdq6rcdrtlxrxgdygl3hzzsvhw2z3m2se7pr2x30zs9d5pa300cftd77exfteqyhnqe2t7rc
# ls -1 ~/priv/key_2107*
# key_2107_pay.addr  key_2107_pay.skey  key_2107_pay.vkey  key_2107_stake.addr  key_2107_stake.skey  key_2107_stake.vkey
```
