!> Note that if you'd like to use Import function to import a Daedalus/Yoroi based 15 or 24 word wallet seed, please ensure that you've rebuilt your `cardano-node` using instructions [here]() or alternately ensure that `cardano-address` and `bech32` are available in your $PATH environment variable.

This chapter describes some common tasks for wallet and pool creation when running CNTools in Online mode.  
CNTools contains more functionality not described here.

!> Familiarize yourself with the Online workflow of creating wallets and pools on the TestNet. You can then move on to test the [Offline Workflow](#offline-workflow). The Offline workflow means that the private keys never touch the Online node. First when comfortable with both the online and offline CNTools workflow, it's time to deploy what you learnt on MainNet.

Step by Step guide to create a pool with CNTools in Online mode

* [Create Wallet](#create-wallet) - a wallet is needed for pledge and to pay for pool registration fee
* [Create Pool](#create-pool) - create the necessary pool keys 
* [Register Pool](#create-pool) - register the pool on-chain


##### Create Wallet

**1.** Choose `[w] Wallet` and you will be presented with the following menu:
```
 >> WALLET
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Wallet Management

 ) New      -  create a new wallet
 ) Import   -  import a Daedalus/Yoroi 15/24 word Shelley mnemonic created wallet
 ) Register -  register a wallet on chain (hybrid/offline mode)
 ) List     -  list all available wallets in a compact view
 ) Show     -  show detailed view of a specific wallet
 ) Remove   -  remove a wallet
 ) Decrypt  -  remove write protection and decrypt wallet
 ) Encrypt  -  encrypt wallet keys and make all files immutable
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Select Wallet operation

  [n] New
  [i] Import
  [r] Register
  [l] List
  [s] Show
  [x] Remove
  [d] Decrypt
  [e] Encrypt
  [h] Home
```
**2.** Choose `[n] New` to create a new wallet. `[i] Import` can also be used to import a Daedalus/Yoroi based 15 or 24 word wallet seed  
**3.** Give the wallet a name  
**4.** CNTools will give you the wallet address.  For example:
```
 >> WALLET >> NEW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Name of new wallet: Test

New Wallet          : Test
Address             : addr1qxl3cdy7ln0862uwcz7w5slrrueqat54szlevnmt2cyp2mq76qfnv45vcewg6tgsfccpltkmd3ukxhgql93mmncrahsqnkk3lq
Enterprise Address  : addr1vxl3cdy7ln0862uwcz7w5slrrueqat54szlevnmt2cyp2mqt5kfd7

You can now send and receive ADA using the above. Note that Enterprise Address will not take part in staking.
Wallet will be automatically registered on chain if you
choose to delegate or pledge wallet when registering a stake pool.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```
**5.**  Send some money to this wallet. Either through the faucet or have a friend send you some.

!> The wallet must have funds in it before you can proceed.  


##### Create Pool

**1.** From the main menu select `[p] Pool`
```
 >> POOL
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Pool Management

 ) New        -  create a new pool
 ) Register   -  register created pool on chain using a stake wallet (pledge wallet)
 ) Modify     -  change pool parameters and register updated pool values on chain
 ) Retire     -  de-register stake pool from chain in specified epoch
 ) List       -  a compact list view of available local pools
 ) Show       -  detailed view of specified pool
 ) Delegators -  list all delegators for pool
 ) Rotate     -  rotate pool KES keys
 ) Decrypt    -  remove write protection and decrypt pool
 ) Encrypt    -  encrypt pool cold keys and make all files immutable
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Select Pool operation

  [n] New
  [r] Register
  [m] Modify
  [x] Retire
  [l] List
  [s] Show
  [g] Delegators
  [o] Rotate
  [d] Decrypt
  [e] Encrypt
  [h] Home
``` 
**2.**  Select `[n] New` to create a new pool  
**3.**  Give the pool a name. In our case, we call it LOVE.  The result should look something like this:
```
 >> POOL >> NEW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Pool Name: TEST

Pool: TEST
PoolPubKey: 88367d5f4fde9c6b3c3c7c0a17ec4a9e46039cb01032cc2baa738b41
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

##### Register Pool

**1.**  From the main menu select `[p] Pool`  
**2.**  Select `[r] Register`  
**3.**  Select the pool you just created  
**4.**  CNTools will give you prompts to set pledge, margin, cost, metadata, and relays. Enter values that are useful to you.  

!> Make sure you set your pledge low enough to insure your funds in your wallet will cover pledge plus pool registration fees.  

**5.**  Select wallet to use as pledge wallet, `bob` in our case.  
As this is a newly created wallet you will be prompted to press a key to continue with wallet registration.  
When complete and if successful, both wallet and pool will be registered on-chain.

It will look something like this:
```
 >> POOL >> REGISTER
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Dumping ledger-state from node, can take a while on larger networks...

Select Pool:

  TEST
  [c] Cancel

 -- Pool Parameters --

Pledge (in ADA, default: 50000): 899
Margin (in %, default: 7.5): 10
Cost (in ADA, default: 256): 500

 -- Pool Metadata --

Enter Pool's Name (default: TEST):
Enter Pool's Ticker , should be between 3-5 characters (default: TEST):
Enter Pool's Description (default: No Description): My custom description
Enter Pool's Homepage (default: https://foo.com): https://test.com
Enter Pool's JSON URL to host metadata file - URL length should be less than 64 chars (default: https://foo.bat/poolmeta.json): https://test.com/poolmeta.json

Please make sure you host your metadata JSON file (with contents as below) at https://love.fake.com/poolmeta.json :

{
  "name": "TEST",
  "ticker": "TEST",
  "description": "My custom description",
  "homepage": "https://test.com"
}

 -- Pool Relay Registration --

  [d] A or AAAA DNS record  (single)
  [4] IPv4 address (multiple)
  [c] Cancel

Enter relays's DNS record, only A or AAAA DNS records (default: ): relay.test.com
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


**8.**  Start or restart your cardano-node (eg: if using cnode.sh, update parameters in that file) with the parameters as shown.  This will ensure your node has all the information necessary to create blocks.

#### Offline Workflow

For offline workflow all wallet and pool keys should be kept on the offline node. The backup function in CNTools has an option to create a backup without private keys to be transfered to online node.

Keys excluded from backup when created without private keys:  
**Wallet** - payment.skey, stake.skey
**Pool**   - cold.skey

All other files are included in the backup to be transfered to the online node.

``` mermaid

sequenceDiagram
    Note over Offline: Create/Import a new wallet
    Note over Offline: Create a new pool
    Note over Offline: Rotate KES keys to generate op.cert
    Note over Offline: Create a backup w/o private keys
    Offline->>Online: Transfer backup to online node
    Note over Online: Fund the wallet base address with enough Ada
    Note over Online: Register wallet using ' Wallet » Register ' in hybrid mode
    Online->>Offline: Transfer built tx back to offline node
    Note over Offline: Use ' Sign Tx ' with payment.skey from wallet to sign transaction
    Offline->>Online: Transfer signed tx back to online node
    Note over Online: Use ' Submit Tx ' to send signed transaction to blockchain
    Note over Online: Register pool in hybrid mode
    loop
        Offline-->Online: Repeat steps to sign and submit built pool registration transaction
    end
    Note over Online: Verify that pool was successfully registered with ' Pool » Show '

```
