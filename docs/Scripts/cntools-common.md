# Common tasks
This chapter describes some common tasks for wallet and pool creation.  
CNTools contains more functionality not described here. 

Step by Step guide to create a pool with CNTools

* [Stake Wallet](#stake-wallet)  
a stake wallet is needed for delegation/pledge
* [Create Pool](#create-pool)  
create the necessary pool keys 
* [Register Pool](#create-pool)  
register the pool on-chain


#### Stake Wallet

**1.** `Choose Wallet [w]` and you will be presented with the following menu:
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
**2.** Choose `New [n]` to go to submenu for creating a new wallet
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
**3.** Choose `Payment [p]` type of wallet  
**4.** Give the wallet a name  
**5.** CNTools will give you your payment address.  For example:
```
 >> WALLET >> NEW >> PAYMENT
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Name of new wallet: bob

New Wallet: bob
Payment Address: 60f8a4bed2e379cf8ee5aa28bb7b227362b38694368b767b270720760503132fc5
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```
**6.**  Send some money to this wallet. Either through the faucet or have a friend send you some.  
**IMPORTANT** - The wallet must have funds in it before you can proceed.  
**7.**  From the main menu choose `Wallet >> New` and then this time choose `Stake [s]` to upgrade your wallet  
**8.**  CNTools will give you a list of wallets you can upgrade. Choose the wallet you created in step 4. In this example case, that wallet is called `bob`. This will send a transaction to the blockchain to upgrade your wallet to a staking wallet. The result should look something like this:
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


#### Create Pool

**1.** From the main menu select `Pool [p]`
```
 >> POOL
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Pool Management

 ) New       -  create a new pool
 ) Register  -  register created pool on chain using a stake wallet (pledge wallet)
 ) Modify    -  change pool parameters and register updated pool values on chain
 ) Retire    -  de-register stake pool from chain in specified epoch
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
  [x] Retire
  [l] List
  [s] Show
  [o] Rotate
  [d] Decrypt
  [e] Encrypt
  [h] Home
``` 
**2.**  Select `New [n]` to create a new pool  
**3.**  Give the pool a name. In our case, we call it LOVE.  The result should look something like this:
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
4.  Start or restart your cardano-node with the parameters as shown.  This will ensure your node has all the information necessary to create blocks.  
**IMPORTANT** - If you do not start your node with these parameters you won't be able to make blocks.


#### Register Pool

**1.**  From the main menu select `Pool [p]`  
**2.**  Select `Register [r]`  
**3.**  Select the pool you just created in step 11 above  
**4.**  CNTools will give you prompts to set metadata, pledge, margin and cost. Enter values that are useful to you.  
**IMPORTANT** - Make sure you set your pledge low enough to insure your funds in your wallet will cover pledge plus pool registration fees.  

It will look something like this:
```
 >> POOL >> REGISTER
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Select Pool:

  LOVE
  [c] Cancel

Pledge (in ADA, default: 50000): 899
Margin (in %, default: 7.5): 10
Cost (in ADA, default: 256): 500
Enter Pool's Name (default: LOVE):
Enter Pool's Ticker , should be between 3-5 characters (default: LOVE):
Enter Pool's Description (default: No Description): My custom description
Enter Pool's Homepage (default: https://foo.com): https://love.fake.com
Enter Pool's JSON URL to host metadata file - URL length should be less than 64 chars (default: https://foo.bat/poolmeta.json): https://love.fake.com/poolmeta.json

Please make sure you host your metadata JSON file (with contents as below) at https://love.fake.com/poolmeta.json :
{
  "name": "LOVE",
  "ticker": "LOVE",
  "description": "My custom description",
  "homepage": "https://love.fake.com"
}
```
**5.**  Select the wallet you want to register the pool with.  
**6.**  DONE!  

The final output on successful registration should look something like this:
```
New block was created - 23414

Pool LOVE successfully registered using wallet bob for pledge
Pledge : 899 ADA
Margin : 10%
Cost   : 500 ADA
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```










 

