# Quickstart for using CNTOOLS
CNTOOLS is a shell script that will simplify typical operations used in FF and HTN testnets.  We have developed this for our own use, and as such tend to follow some well worn paths when using it.  See below for simple step by step guide for getting a pool setup on the FF network.  Please note that this tool is tested on linux platforms only at this point.
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

 ) Wallet  -  create, show, remove and protect wallets
 ) Funds   -  send and delegate ADA
 ) Pool    -  pool creation and management
 ) Update  -  install or upgrade latest available binary of Haskell Cardano
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 What would you like to do?

  [w] Wallet
  [f] Funds
  [p] Pool
  [u] Update
  [q] Quit
```
# Step by Step to create a pool with CNTOOLS

1. Choose **Wallet** [w] and you will be presented with the following menu:
```
 >> WALLET
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Wallet Management

 ) New      -  create a new payment wallet or upgrade existing to a stake wallet
 ) List     -  list all available wallets in a compact view
 ) Show     -  show detailed view of a specific wallet
 ) Remove   -  remove a wallet
 ) Decrypt  -  remove write protection and decrypt wallet
 ) Encrypt  -  encrypt wallet keys and make all files immutable
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Select wallet operation

  [n] New
  [l] List
  [s] Show
  [r] Remove
  [d] Decrypt
  [e] Encrypt
  [h] Home
```
2. Choose **New** [n] to go to submenu for creating a new wallet
```
 >> WALLET >> NEW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Wallet Type

 ) Payment  -  First step for a new wallet
               A payment wallet can send and receive funds but not delegate/pledge.

 ) Stake    -  Upgrade existing payment wallet to a stake wallet
               Make sure there are funds available in payment wallet before upgrade
               as this is needed to pay for the stake wallet registration fee.
               A stake wallet is needed to be able to delegate and pledge to a pool.
               All funds from payment address will be moved to base address.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

 Choose wallet type

  [p] Payment
  [s] Stake
  [h] Home
```
3. Choose **Payment** [p] type of wallet
4. Give the wallet a name
5. CNTOOLS will give you your payment address.  For example:
```
 >> WALLET >> NEW >> PAYMENT
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Name of new wallet: bob

New Wallet: bob
Payment Address: 60f8a4bed2e379cf8ee5aa28bb7b227362b38694368b767b270720760503132fc5
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```
6.  **Send some money to this wallet.**  Either through the faucet or have a friend send you some.  IMPORTANT...  The wallet must have funds in it before you can proceed.
7.  From the main menu choose **Wallet >> New** and then this time choose **Stake** [s] to upgrade your wallet
8.  CNTOOLS will give you a list of wallets you can upgrade.  Choose the wallet you created in step 4.  In this example case that wallet is called **bob**.   This will send a transaction to the blockchain to upgrade your wallet to a staking wallet. The result should look something like this:
```
New block was created - 23386
New Stake Wallet : bob
Payment Address  : 60f8a4bed2e379cf8ee5aa28bb7b227362b38694368b767b270720760503132fc5
Payment Balance  : 0 ADA
Base Address     : 00f8a4bed2e379cf8ee5aa28bb7b227362b38694368b767b270720760503132fc545bdb48005781a47a864347843654fd58c1363695453697b5b59fd7ca2af3dc8
Base Balance     : 99.428691 ADA
Reward Address   : 5821e045bdb48005781a47a864347843654fd58c1363695453697b5b59fd7ca2af3dc8
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```
The total balance is 0 for the payment address because ALL funds have been moved to the base address.  

9. From the main menu select **Pool** [p]
```
 >> POOL
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Pool Management

 ) New       -  create a new pool
 ) Register  -  register created pool on chain using a stake wallet (pledge wallet)
 ) Modify    -  change pool parameters and register updated pool values on chain
 ) List      -  a compact list view of available local pools
 ) Show      -  detailed view of specified pool
 ) Rotate    -  rotate pool KES keys
 ) Decrypt   -  remove write protection and decrypt pool
 ) Encrypt   -  encrypt pool cold keys and make all files immutable
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Select wallet operation

  [n] New
  [r] Register
  [m] Modify
  [l] List
  [s] Show
  [o] Rotate
  [d] Decrypt
  [e] Encrypt
  [h] Home
```
10.  Select **New** [n] to create a new pool
11.  Give the pool a name. In our case we call it LOVE.  The result should look something like this:
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
12.  Start or restart your cardano-node with the parameters as shown.  This will insure your node has all the information necessary to create blocks.  
**IMPORTANT**.  If you do not start your node with these parameters you won't be able to make blocks.
13.  From the main menu select **pool** [p]
14.  Select **Register** [r]
15.  Select the pool you just created in step 11 above
16.  CNTOOLS will give you prompts to set pledge, margin and cost.  Enter values that are useful to you.  Make sure you set your pledge low enough to insure your funds in your wallet will cover pledge plus pool registration fees.  It will look something like this:
```
Pledge (in ADA, default: 50000): 899
Margin (in %, default: 7): 10
Cost (in ADA, default: 256): 500
```
17.  Select the wallet you want to register the pool with.  
18.  DONE!  The output should look something like this:
```
New block was created - 23414

--- Balance Check Source Address -------------------------------------------------------
                           TxHash                                 TxIx        Lovelace
----------------------------------------------------------------------------------------
3caee84b8e5deaaa4482763b5322aa209fb3c16adc0fe80fc35640787c3d2423     0         599242070

Total balance is 599.24207 ADA

Pool LOVE successfully registered using wallet bob for pledge
Pledge : 899 ADA
Margin : 10%
Cost   : 500 ADA
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```










 

