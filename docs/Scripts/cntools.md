# CNTools
CNTools is a shell script that will simplify typical operations for wallets and pool management. The tool is developed against the latest master branch of [cardano-node](https://github.com/input-output-hk/cardano-node) and as such may contain breaking changes not compatible with all testnet networks running against a specific tag. As the code matures these breaking changes should be less frequent. Please note that this tool is tested on Linux platforms only at this point.

The script assumes the [Pre-Requisites](../Common.md#dependencies-and-folder-structure-setup) have already been run.

* [Overview](#overview)
* [Download and Update](#download-and-update)
* [Start CNTools](#start)
* [Navigation](#navigation)

#### Overview
The tool consist of four files.  
* **`cntools.sh`**  
the main script to launch cntools.
* **`cntools.library`**  
internal script with helper functions.
* **`cntools.config`**  
configuration file to modify certain behaviours, paths and name schema used.
* **`cntoolsBlockCollector.sh`**  
a script to be run in background on core node parsing log file for block traces.  
see [Block Collector](cntools-blocks.md) section for more details.

In addition to the above files, there is also a dependency on the common `env` file. CNTools connects to your node through the configuration in the `env` file located in the same directory as the script. Customize `env` and `cntools.config` files for your needs.  CNTools will start even if your node is offline, but don't expect to get very far.

#### Download and Update

If you have run `prereqs.sh`, this should already be available in your scripts folder and make this step unnecessary. 

To download cntools manually you can execute the commands below:
``` bash
cd $CNODE_HOME/scripts
wget -O cntools.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.sh
wget -O cntools.config https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.config
wget -O cntools.library https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.library
wget -O cntoolsBlockCollector.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntoolsBlockCollector.sh
wget -O env https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/env
chmod 750 cntools.sh cntoolsBlockCollector.sh
chmod 640 cntools.config cntools.library env
```

#### Start
`$ ./cntools.sh`

You should get a screen that looks something like this:
```
 >> CNTOOLS <<                                       A Guild Operators collaboration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Main Menu

 ) Wallet  -  create, show, remove and protect wallets
 ) Funds   -  send, withdraw and delegate
 ) Pool    -  pool creation and management
 ) Blocks  -  show core node leader slots
 ) Update  -  update cntools script and library config files
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 What would you like to do?

  [w] Wallet
  [f] Funds
  [p] Pool
  [b] Blocks
  [u] Update
  [q] Quit
```

#### Navigation
The scripts menu supports both arrow key navigation and shortcut key selection. The character within the square brackets is the shortcut to press for quick navigation. For other selections like wallet and pool menu that doesn't contain shortcuts, there is a third way to navigate. Key pressed is compared to the first character of the menu option and if there is a match selection jumps to this location. A handy way to quickly navigate a large menu. 