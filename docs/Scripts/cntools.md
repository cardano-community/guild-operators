!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

CNTools is like a swiss army knife for pool operators to simplify typical operations regarding their wallet keys and pool management. Please note that this tool is tested on Linux platforms only at this point and should **NOT** act as an excuse for Pool Operators to skip reading about how Staking works or basics of Linux operations. The skills highlighted in [official documentation](https://docs.cardano.org/en/latest/getting-started/stake-pool-operators/prerequisites.html) are paramount for a stake pool operator, and so is the understanding of configuration files and network.

Visit the [Changelog](Scripts/cntools-changelog.md) section to see progress and current release.

* [Overview](#overview)
* [Download and Update](#download-and-update)
* [Start CNTools](#start)
* [Navigation](#navigation)

##### Overview
The tool consist of four files.  
* `cntools.sh` - the main script to launch cntools.
* `cntools.library` - internal script with helper functions.
* `cntools.config` - configuration file to modify certain behaviours, paths and name schema used.
* `cntoolsBlockCollector.sh` - a script to be run in background on core node parsing log file for block traces, see [Block Collector](Scripts/cntools-blocks.md) section for more details.

In addition to the above files, there is also a dependency on the common `env` file. CNTools connects to your node through the configuration in the `env` file located in the same directory as the script. Customize `env` and `cntools.config` files for your needs. CNTools will start even if your node is offline, but don't expect to get very far.

> The tool in its default state uses the folder structure [here](basics.md#folder-structure). Everyone is free to customise, but while doing so beware that you may introduce changes that were not tested.

##### Download and Update

The update functionality is provided from within cntools. In case of breaking changes, please follow the prompts post upgrade. If stuck, its always best to re-run latest prereqs before proceeding.

##### Start
`$ ./cntools.sh`

You should get a screen that looks something like this:
```
 >> CNTools X.X.X <<                                 A Guild Operators collaboration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Main Menu

 ) Wallet  -  create, show, remove and protect wallets
 ) Funds   -  send, withdraw and delegate
 ) Pool    -  pool creation and management
 ) Blocks  -  show core node leader slots
 ) Update  -  update cntools script and library config files
 ) Backup  -  backup & restore of wallet/pool/config
 ) Refresh -  reload home screen content
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                                                    Epoch 3 - 01h:03m:38s until next
 What would you like to do?                                        Node Sync: -22 :|

  [w] Wallet
  [f] Funds
  [p] Pool
  [b] Blocks
  [u] Update
  [z] Backup & Restore
  [r] Refresh
  [q] Quit
```

##### Navigation
The scripts menu supports both arrow key navigation and shortcut key selection. The character within the square brackets is the shortcut to press for quick navigation. For other selections like wallet and pool menu that doesn't contain shortcuts, there is a third way to navigate. Key pressed is compared to the first character of the menu option and if there is a match selection jumps to this location. A handy way to quickly navigate a large menu. 
