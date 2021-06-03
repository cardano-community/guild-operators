!> Note that if you'd like to use Import function to import a Daedalus/Yoroi based 15 or 24 word wallet seed, please ensure that you've rebuilt your `cardano-node` using instructions [here]() or alternately ensure that `cardano-address` and `bech32` are available in your $PATH environment variable.

This chapter describes some common tasks for wallet and pool creation when running CNTools in Online mode.  
CNTools contains more functionality not described here.

!> Familiarize yourself with the Online workflow of creating wallets and pools on the Testnet. You can then move on to test the [Offline Workflow](#offline-workflow). The Offline workflow means that the private keys never touch the Online node. When comfortable with both the online and offline CNTools workflow, it's time to deploy what you learnt on the mainnet.

Step by Step guide to create a pool with CNTools in Online mode

* [Create Wallet](#create-wallet) - a wallet is needed for pledge and to pay for pool registration fee
* [Create Pool](#create-pool) - create the necessary pool keys 
* [Register Pool](#create-pool) - register the pool on-chain


##### Create Wallet

**1.** Choose `[w] Wallet` and you will be presented with the following menu:
```
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 >> WALLET
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Wallet Management

 ) New         - create a new wallet
 ) Import      - import a Daedalus/Yoroi 24/25 mnemonic or Ledger/Trezor HW wallet
 ) Register    - register a wallet on chain
 ) De-Register - De-Register (retire) a registered wallet
 ) List        - list all available wallets in a compact view
 ) Show        - show detailed view of a specific wallet
 ) Remove      - remove a wallet
 ) Decrypt     - remove write protection and decrypt wallet
 ) Encrypt     - encrypt wallet keys and make all files immutable
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Select Wallet Operation

  [n] New
  [i] Import
  [r] Register
  [z] De-Register
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
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 >> WALLET >> NEW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Name of new wallet: Test

New Wallet         : Test
Address            : addr_test1qpq5qjr774cyc6kxcwp060k4t4hwp42q43v35lmcg3gcycu5uwdwld5yr8m8fgn7su955zf5qahtrgljqfjfa4nr8jfsj4alxk
Enterprise Address : addr_test1vpq5qjr774cyc6kxcwp060k4t4hwp42q43v35lmcg3gcyccuxhdka

You can now send and receive Ada using the above addresses.
Note that Enterprise Address will not take part in staking.
Wallet will be automatically registered on chain if you
choose to delegate or pledge wallet when registering a stake pool.
```
**5.**  Send some money to this wallet. Either through the faucet or have a friend send you some.

!> The wallet must have funds in it before you can proceed.  


##### Create Pool

**1.** From the main menu select `[p] Pool`
```
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 >> POOL
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Pool Management

 ) New      - create a new pool
 ) Register - register created pool on chain using a stake wallet (pledge wallet)
 ) Modify   - change pool parameters and register updated pool values on chain
 ) Retire   - de-register stake pool from chain in specified epoch
 ) List     - a compact list view of available local pools
 ) Show     - detailed view of specified pool
 ) Rotate   - rotate pool KES keys
 ) Decrypt  - remove write protection and decrypt pool
 ) Encrypt  - encrypt pool cold keys and make all files immutable
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Select Pool Operation

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
**2.**  Select `[n] New` to create a new pool  
**3.**  Give the pool a name. In our case, we call it TEST. The result should look something like this:
```
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 >> POOL >> NEW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Pool Name: TEST

Pool: TEST
ID (hex)    : 8d5a3510f18ce241115da38a1b2419ed82d308599c16e98caea1b4c0
ID (bech32) : pool134dr2y833n3yzy2a5w9pkfqeakpdxzzenstwnr9w5x6vqtnclue
```

##### Register Pool

**1.**  From the main menu select `[p] Pool`  
**2.**  Select `[r] Register`  
**3.**  Select the pool you just created  
**4.**  CNTools will give you prompts to set pledge, margin, cost, metadata, and relays. Enter values that are useful to you.  

!> Make sure you set your pledge low enough to insure your funds in your wallet will cover pledge plus pool registration fees.  

**5.**  Select wallet to use as pledge wallet, `Test` in our case.  
As this is a newly created wallet you will be prompted to press a key to continue with wallet registration.  
When complete and if successful, both wallet and pool will be registered on-chain.

It will look something like this:
```
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 >> POOL >> REGISTER
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Online mode  -  The default mode to use if all keys are available

Hybrid mode  -  1) Go through the steps to build a transaction file
                2) Copy the built tx file to an offline node
                3) Sign it using 'Sign Tx' with keys on offline node
                   (CNTools started in offline mode '-o' without node connection)
                4) Copy the signed tx file back to the online node and submit using 'Submit Tx'

Selected value: [o] Online

# Select pool
Selected pool: TEST

# Pool Parameters
press enter to use default value

Pledge (in Ada, default: 50,000):
Margin (in %, default: 7.5):
Cost (in Ada, minimum: 340, default: 340):

# Pool Metadata

Enter Pool's JSON URL to host metadata file - URL length should be less than 64 chars (default: https://foo.bat/poolmeta.json):

Enter Pool's Name (default: TEST):
Enter Pool's Ticker , should be between 3-5 characters (default: TEST):
Enter Pool's Description (default: No Description):
Enter Pool's Homepage (default: https://foo.com):

Optionally set an extended metadata URL?
Selected value: [n] No
{
  "name": "TEST",
  "ticker": "TEST",
  "description": "No Description",
  "homepage": "https://foo.com",
  "nonce": "1613146429"
}

Please host file /opt/cardano/guild/priv/pool/TEST/poolmeta.json as-is at https://foo.bat/poolmeta.json

# Pool Relay Registration
Selected value: [d] A or AAAA DNS record (single)
Enter relays's DNS record, only A or AAAA DNS records: relay.foo.com
Enter relays's port: 6000
Add more relay entries?
Selected value: [n] No

# Select main owner/pledge wallet (normal CLI wallet)
Selected wallet: Test (100,000.000000 Ada)
Wallet Test3 not registered on chain

Waiting for new block to be created (timeout = 600 slots, 600s)
INFO: press any key to cancel and return (won't stop transaction)

Owner #1 : Test added!

Register a multi-owner pool (you need to have stake.vkey of any additional owner in a seperate wallet folder under $CNODE_HOME/priv/wallet)?
Selected value: [n] No

Use a separate rewards wallet from main owner?
Selected value: [n] No

Waiting for new block to be created (timeout = 600 slots, 600s)
INFO: press any key to cancel and return (won't stop transaction)

Pool TEST successfully registered!
Owner #1      : Test
Reward Wallet : Test
Pledge        : 50,000 Ada
Margin        : 7.5 %
Cost          : 340 Ada

Uncomment and set value for POOL_NAME in ./env with 'TEST'

INFO: Total balance in 1 owner/pledge wallet(s) are: 99,497.996518 Ada
```


**6.** As mentioned in the above output: *Uncomment and set value for `POOL_NAME` in `./env` with 'TEST'* (in our case, the `POOL_NAME` is `TEST`).

The `cnode.sh` script will automatically detect whether the files required to run as a block producing node are present in the `$CNODE_HOME/priv/pool/<POOL_NAME>` directory.

**7.** Rotate KES keys for the first time to generate the operational certificate - `op.cert`.

*  From the main menu select `[p] Pool`  
*  Select `[o] Rotate`  
*  Select the pool you just created  
*  
The output should look like:

```
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 >> POOL >> ROTATE KES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Select pool to rotate KES keys on
Selected pool: TEST

Pool KES keys successfully updated
New KES start period  : 240
KES keys will expire  : 302 - 2021-09-04 11:24:31 UTC

Restart your pool node for changes to take effect

press any key to return to home menu
```


**8.** Start or restart your `cardano-node`.

If deployed as a `systemd` service as shown [here](Build/node-cli?id=run-as-systemd-service), you can run `sudo systemctl restart cnode`.

**8.** Ensure the node is running as a block producing (core) node.

You can use [gLiveView](Scripts/gliveview) - the output at the top should say `> Cardano Node - (Core - Testnet)`.

Alternatively, you can check the node logs in `$CNODE_HOME/logs/` to see whether the node is performing leadership checks (`TraceStartLeadershipCheck`, `TraceNodeIsNotLeader`, etc.) 

