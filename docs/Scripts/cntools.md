!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

CNTools is like a swiss army knife for pool operators to simplify typical operations regarding their wallet keys and pool management. Please note that this tool is tested on Linux platforms only at this point and should **NOT** act as an excuse for Pool Operators to skip reading about how Staking works or basics of Linux operations. The skills highlighted in [official documentation](https://docs.cardano.org/en/latest/getting-started/stake-pool-operators/prerequisites.html) are paramount for a stake pool operator, and so is the understanding of configuration files and network.

Visit the [Changelog](Scripts/cntools-changelog.md) section to see progress and current release.

* [Overview](#overview)
* [Download and Update](#download-and-update)
* [Start CNTools](#start)
* [Navigation](#navigation)

##### Overview
The tool consist of three files.  
* `cntools.sh` - the main script to launch cntools.
* `cntools.library` - internal script with helper functions.
* `cntools.config` - configuration file to modify certain behaviours, paths and name schema used.

In addition to the above files, there is also a dependency on the common `env` file. CNTools connects to your node through the configuration in the `env` file located in the same directory as the script. Customize `env` and `cntools.config` files for your needs. CNTools can operate in an Offline mode without node access by providing the `-o` runtime argument. This launches CNTools with a limited set of features with Hybrid or Online v/s Offline workflow in mind.

`cncli.sh` is a companion script that are optional to run on the core node(block producer) to be able to monitor blocks created and by running leader schedule calculation and block validation.  
`logMonitor.sh` is another companion script meant to be run together with cncli.sh script to give a complete picture.  
See [CNCLI](Scripts/cncli.md) and [Log Monitor](Scripts/logmonitor.md) sections for more details.  

> The tool in its default state uses the folder structure [here](basics.md#folder-structure). Everyone is free to customise, but while doing so beware that you may introduce changes that were not tested.

##### Download and Update

The update functionality is provided from within cntools. In case of breaking changes, please follow the prompts post upgrade. If stuck, its always best to re-run latest prereqs before proceeding.

CNTools can be run in online and offline mode. At a very high level, for working with offline devices, remember that you need to use cntools on an online node to generate a staging transaction for the desired type of transaction, and then move the staging transaction to offline mode to sign (authorize) using your offline node keys - and then bring back updated transaction to the online node for submission to chain.

!> It is important that you familiarise yourself with the usage using Testnet network (on a seperate machine) first, read the warnings/messages, maintain your keys and backups with passwords (no one other than yourself can retrieve the funds if you make an accident), before performing actions on mainnet.

##### Start CNTools in Online Mode
`$ ./cntools.sh`

You should get a screen that looks something like this:
```
 >> CNTools vX.X.X - CONNECTED <<                    A Guild Operators collaboration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Main Menu

 ) Wallet    -  create, show, remove and protect wallets
 ) Funds     -  send, withdraw and delegate
 ) Pool      -  pool creation and management
 ) Sign Tx   -  Sign a built transaction file (hybrid/offline mode)
 ) Submit Tx -  Submit a signed transaction file (hybrid/offline mode)
 ) Metadata  -  Post metadata on-chain (e.g voting)
 ) Blocks    -  show core node leader slots
 ) Update    -  update cntools script and library config files
 ) Backup    -  backup & restore of wallet/pool/config
 ) Refresh   -  reload home screen content
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                                                   Epoch 95 - 04h:34m:47s until next
 What would you like to do?                                         Node Sync: 22 :)

  [w] Wallet
  [f] Funds
  [p] Pool
  [s] Sign Tx
  [t] Submit Tx
  [m] Metadata
  [b] Blocks
  [u] Update
  [z] Backup & Restore
  [r] Refresh
  [q] Quit
```

##### Start CNTools in Offline Mode
`$ ./cntools.sh -o`

The main menu header should let you know that node is started in offline mode:
```
 >> CNTools vX.X.X - OFFLINE <<                      A Guild Operators collaboration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

##### Navigation
The scripts menu supports both arrow key navigation and shortcut key selection. The character within the square brackets is the shortcut to press for quick navigation. For other selections like wallet and pool menu that doesn't contain shortcuts, there is a third way to navigate. Key pressed is compared to the first character of the menu option and if there is a match selection jumps to this location. A handy way to quickly navigate a large menu. 
