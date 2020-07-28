This script assists you to create a Private key file and generates a corresponding address script for it
``` bash
cd $CNODE_HOME/scripts
./createAddr.sh
# Usage: ./createAddr.sh <Path with name (prefix) for keys to be created>
# Example:
# createAddr.sh ~/priv/key_2107
# Payment/Enterprise address:
# addr1v9964nsrwp6tr2mr4e3ed3mlwdgug6ajxnnad9q4d4vemzcd0j097
# Base address:
# addr1q9964nsrwp6tr2mr4e3ed3mlwdgug6ajxnnad9q4d4vemz6vfm8a5aq96c0wkrxr5ru3a3xut5qzacfmslakv8yzujfqf0fqhk
# Reward address:
# stake1u9xyan76wszav8htpnp6p7g7cnw96qpwuyac07mxrjpwfysw8j7e8
# ls -1 ~/priv/key_2107*
# key_2107_base.addr key_2107_payment.skey key_2107_payment.vkey key_2107_payment.addr key_2107_stake.skey key_2107_stake.vkey key_2107_reward.addr
```
