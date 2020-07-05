# Common tasks
This chapter describes some common tasks for wallet and pool creation.  
CNTools contains more functionality not described here. 

Step by Step guide to create a pool with CNTools

* [Create Wallet](#create-wallet)  
a wallet is needed for pledge and to pay for pool registration fee
* [Create Pool](#create-pool)  
create the necessary pool keys 
* [Register Pool](#create-pool)  
register the pool on-chain


#### Create Wallet

**1.** `Choose Wallet [w]` and you will be presented with the following menu:
```
 >> WALLET
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Wallet Management

 ) New      -  create a new wallet
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
**2.** Choose `New [n]` to create a new wallet
**3.** Give the wallet a name  
**4.** CNTools will give you the wallet address.  For example:
```
 >> WALLET >> NEW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Name of new wallet: bob

New Wallet : bob
Address    : 00cf9ad54b7f6beac642cd460589e5b42ea40d6848aeeafa5e905855ed249d3d7693cb75605a8bc8edc8cca63cee97a3afb5502d0e8c46d212

You can now send and receive ADA using this address.
Wallet will be automatically registered on chain if you
choose to delegate or pledge wallet when registering a stake pool.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```
**5.**  Send some money to this wallet. Either through the faucet or have a friend send you some.  
**IMPORTANT** - The wallet must have funds in it before you can proceed.  


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
**4.**  Start or restart your cardano-node with the parameters as shown.  This will ensure your node has all the information necessary to create blocks.  
**IMPORTANT** - If you do not start your node with these parameters you won't be able to make blocks.


#### Register Pool

**1.**  From the main menu select `Pool [p]`  
**2.**  Select `Register [r]`  
**3.**  Select the pool you just created  
**4.**  CNTools will give you prompts to set pledge, margin, cost, metadata, and relays. Enter values that are useful to you.  
**IMPORTANT** - Make sure you set your pledge low enough to insure your funds in your wallet will cover pledge plus pool registration fees.  
**5.**  Select wallet to use as pledge wallet, `bob` in our case.  
As this is a newly created wallet you will be prompted to press a key to continue with wallet registration.  
When complete and if successful, both wallet and pool will be registered on-chain.

It will look something like this:
```
 >> POOL >> REGISTER
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Dumping ledger-state from node, can take a while on larger networks...

Select Pool:

  LOVE
  [c] Cancel

 -- Pool Parameters --

Pledge (in ADA, default: 50000): 899
Margin (in %, default: 7.5): 10
Cost (in ADA, default: 256): 500

 -- Pool Metadata --

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

 -- Pool Relay Registration --

  [d] A or AAAA DNS record  (single)
  [4] IPv4 address (multiple)
  [c] Cancel

Enter relays's DNS record, only A or AAAA DNS records (default: ): relay1.love.fake.com
Enter relays's port (default: ): 3001

Select Pledge Wallet:

  bob  (1000.991236 ADA)
  [c] Cancel

Funds in pledge wallet: 1000.991236 ADA

Wallet not registered on chain, press any key to continue with registration

... *wallet registration and pool registration output* ... 
```
**7.**  DONE!  

The final output on successful registration should look something like this:
```
New block was created - 23414

Pool LOVE successfully registered using wallet bob for pledge
Pledge : 899 ADA
Margin : 10%
Cost   : 500 ADA
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```










 

