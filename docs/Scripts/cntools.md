# Quickstart for using CNTOOLS
CNTOOLS is a simple shell script that will simplify typical operations used in FF and HTN testnets.  We have developed this for our own use, and as such tend to follow some well worn paths when using it.  See below for simple step by step guide for getting a pool setup on the FF network.  Please note that this tool is tested on linux platforms only at this point.
The script assumes the [Pre-Requisites](../Common.md#dependencies-and-folder-structure-setup) have already been run.

#### Download and Configuration cntools.sh

If you have run `prereqs.sh`, this should already be available in your scripts folder and make this step unnecessary. 

CNTOOLS connects to your node through the configuration in the env file located in the same directory as the script.  Customize this file for your needs.  CNTOOLS will start even if you node is offline, but don't expect to get very far.

To download cntools manually you can execute the commands below:
``` bash
cd $CNODE_HOME/scripts
curl -s -o cntools.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.sh
curl -s -o cntools.config https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.config
curl -s -o cntools.library https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.library
curl -s -o env https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/env
chmod 750 cntools.sh
chmod 640 cntools.config cntools.library env 
```

#### Start
Insure the tool is executable and start it with:
```
$ ./cntools.sh
```
You should get a screen that looks something like this:
```
 >> CNTOOLS <<                                       A Guild Operators collaboration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   Main Menu
   1) update
   2) wallet  [ new / upgrade | list | show | remove |
                decrypt / unlock | encrypt / lock ]
   3) funds   [ send | delegate ]
   4) pool    [ new | register | list | show | rotate KES |
                decrypt / unlock | encrypt / lock ]
   q) quit
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
What would you like to do? (1-4):
```
# Step by Step to create a pool with CNTOOLS

1. Choose **wallet** (option  2)
```
 >> WALLET
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   Wallet Management

   1) new / upgrade
   2) list
   3) show
   4) remove
   5) decrypt / unlock
   6) encrypt / lock
   h) home
   q) quit
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
What wallet operation would you like to perform? (1-6):
```
2. Choose **new / upgrade** (option  1)
```
 >> WALLET >> NEW / UPGRADE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   Wallet Type

   1) payment  - First step for a new wallet
                 A payment wallet can send and receive funds but not delegate/pledge.

   2) stake    - Upgrade existing payment wallet to a stake wallet
                 Make sure there are funds available in payment wallet before upgrade
                 as this is needed to pay for the stake wallet registration fee.
                 A stake wallet is needed to be able to delegate and pledge to a pool.
                 All funds from payment address will be moved to base address.
   h) home
   q) quit
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Choose wallet type (1-2):
```
3. Choose **payment** type of wallet (option  1)
4. Give the wallet a name
5. CNTOOLS will give you your payment address.  For example:
```
>> WALLET >> NEW >> PAYMENT
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Name of new wallet: bob

Wallet: bob
Payment Address: 60ca926192c09b2fc689b5258d9265038c4270e1f1934413255822db1f9645e2c1
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```
6.  **Send some money to this wallet.**  Either through the faucet or have a friend send you some.  IMPORTANT...  The wallet must have funds in it before you can proceed.
7.  From the main menu choose **wallet** (option #2) and then this time choose **stake** (option #2) to upgrade your wallet
8.  CNTOOLS will give you a list of wallets you can upgrade.  choose the wallet you created in step 4.  In this example case that wallet is called **bob**.   This will send a transaction to the blockchain to upgrade your wallet to a staking wallet.  the result should look something like this:
```
--- Balance Check Source Address -------------------------------------------------------

Total balance in 0 UTxO is 0 Lovelaces or 0 ADA
Wallet: bob
Payment Address: 60ca926192c09b2fc689b5258d9265038c4270e1f1934413255822db1f9645e2c1
Reward Address:  5821e00e0798d1028c9fcd1a1ac2cb0a6af63dd51deb018dfd2fa91abe32c27490e980
Base Address:    00ca926192c09b2fc689b5258d9265038c4270e1f1934413255822db1f9645e2c10e0798d1028c9fcd1a1ac2cb0a6af63dd51deb018dfd2fa91abe32c27490e980
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```
The total balance is 0 for the payment address because ALL funds have been moved to the base address.
9.  From the main menu select **pool** (option 4)
```
>> POOL
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   Pool Management

   1) new
   2) register
   3) list
   4) show
   5) rotate KES keys
   6) decrypt / unlock
   7) encrypt / lock
   h) home
   q) quit
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
What pool operation would you like to perform? (1-7):
```
10.  select **new** to create a new pool (option 1)
11.  Give the pool a name.  in our case we call it LOVE.  The result should look something like this:
```
 >> POOL >> NEW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Pool Name: LOVE

Pool: LOVE
PoolPubKey: 687c3f588d996ee5fc751cc581826f63c407b1c46514ef9fe3001fa96d3a75bc
Start cardano node with the following run arguments:
--shelley-kes-key /opt/cardano/cnode/priv/pool/LOVE/hot.skey
--shelley-vrf-key /opt/cardano/cnode/priv/pool/LOVE/vrf.skey
--shelley-operational-certificate /opt/cardano/cnode/priv/pool/LOVE/op.cert
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```
12.  start or restart your cardano-node with the parameters as shown.  This will insure your node has all the information necessary to create blocks.  IMPORTANT.  If you do not start your node with these parameters you won't be able to make blocks.
13.  from the main menu select **pool** (option 4)
14.  select **register** (option 2)
15.  select the pool you just created in step 11 above
16.  CNTOOLS will give you prompts to set pledge, margin and cost.  Enter values that are useful to you.  Make sure you set your pledge low enough to insure your funds in your wallet will cover pledge plus pool registration fees.  It will look something like this:
```
Pledge in ADA (default: 50000): 899
Margin (default: 0.07): 0.10
Cost in ADA (default: 256): 500
```
17.  select the wallet you want to register the pool with.  
18.  DONE!  The output should look something like this:
```
New block was created - 107

--- Balance Check Source Address -------------------------------------------------------
                           TxHash                                 TxIx        Lovelace
----------------------------------------------------------------------------------------
7f4294db8036bf985bea434d2b910176d8b274f8b7a413748b53540138e3dfaa     0         899947600

Total balance in 1 UTxO is 899947600 Lovelaces or 899.9476 ADA

Pool LOVE successfully registered using wallet bob for pledge
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```










 

