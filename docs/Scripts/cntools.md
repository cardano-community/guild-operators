!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

CNTools is like a swiss army knife for pool operators to simplify typical operations regarding their wallet keys and pool management. Please note that this tool is tested on Linux platforms only at this point and should **NOT** act as an excuse for Pool Operators to skip reading about how Staking works or basics of Linux operations. The skills highlighted in [official documentation](https://docs.cardano.org/en/latest/getting-started/stake-pool-operators/prerequisites.html) are paramount for a stake pool operator, and so is the understanding of configuration files and network.

Visit the [Changelog](Scripts/cntools-changelog.md) section to see progress and current release.

* [Overview](#overview)
* [Download and Update](#download-and-update)
* [Navigation](#navigation)
* [Hardware Wallet](#hardware-wallet)
* [Offline Workflow](#offline-workflow)
* [Start CNTools in Online Mode](#start-cntools-in-online-mode)
* [Start CNTools in Offline Mode](#start-cntools-in-offline-mode)

##### Overview
The tool consist of three files.  
* `cntools.sh` - the main script to launch cntools.
* `cntools.library` - internal script with helper functions.
* `cntools.config` - configuration file to modify certain behaviours, paths and name schema used.

In addition to the above files, there is also a dependency on the common `env` file. CNTools connects to your node through the configuration in the `env` file located in the same directory as the script. Customize `env` and `cntools.config` files for your needs. CNTools can operate in an Offline mode without node access by providing the `-o` runtime argument. This launches CNTools with a limited set of features.
* Online - When all wallet and pool keys are available on the hot node, use this option.
* Hybrid - Option on hot node with offline workflow in mind when signing keys are kept off the hot node to create an offline transaction file.
* Offline - When CNTools is launched with `-o` runtime argument. Mainly used to access `Transaction >> Sign` to sign an offline transaction file created in Hybrid mode.

`cncli.sh` is a companion script that are optional to run on the core node(block producer) to be able to monitor blocks created and by running leader schedule calculation and block validation.  
`logMonitor.sh` is another companion script meant to be run together with cncli.sh script to give a complete picture.  
See [CNCLI](Scripts/cncli.md) and [Log Monitor](Scripts/logmonitor.md) sections for more details.  

> The tool in it's default state uses the folder structure [here](basics.md#folder-structure). Everyone is free to customise, but while doing so beware that you may introduce changes that were not tested.

!> It is important that you familiarise yourself with the usage using Testnet network (on a seperate machine) first, read the warnings/messages, maintain your keys and backups with passwords (no one other than yourself can retrieve the funds if you make an accident), before performing actions on mainnet.

##### Download and Update
The update functionality is provided from within CNTools. In case of breaking changes, please follow the prompts post upgrade. If stuck, it's always best to re-run latest prereqs before proceeding.

##### Navigation
The scripts menu supports both arrow key navigation and shortcut key selection. The character within the square brackets is the shortcut to press for quick navigation. For other selections like wallet and pool menu that doesn't contain shortcuts, there is a third way to navigate. Key pressed is compared to the first character of the menu option and if there is a match selection jumps to this location. A handy way to quickly navigate a large menu. 

##### Hardware Wallet
CNTools include hardware wallet support since version 7.0.0 through Vacuumlabs cardano-hw-cli application. Initialize and update firmware/app on the device to the latest version before usage following the manufacturer instructions.

To enable hardware support run `prereqs.sh -w`. This downloads and installs Vacuumlabs cardano-hw-cli including udev configuration. When a new version of Vacuumlabs cardano-hw-cli is released, run `prereqs.sh -w` again to update. For additional runtime options, run `prereqs.sh -h`.

**Ledger**  
Supported devices: Nano S / Nano X  
Make sure the latest cardano app is installed on the device.

**Trezor**  
Supported devices: Model T  
Make sure the latest firmware is installed on the device. In addition to this, install `Trezor Bridge` for your system before trying to use your Trezor device in CNTools. You can find the latest version of the bridge at https://wallet.trezor.io/#/bridge

##### Offline Workflow
CNTools can be run in online and offline mode. At a very high level, for working with offline devices, remember that you need to use CNTools on an online node to generate a staging transaction for the desired type of transaction, and then move the staging transaction to offline node to sign (authorize) using your offline node signing keys - and then bring back updated transaction to the online node for submission to chain. 

For offline workflow all wallet and pool keys should be kept on the offline node. The backup function in CNTools has an option to create a backup without private keys(sensitive signing keys) to be transfered to online node. All other files are included in the backup to be transfered to the online node. 

Keys excluded from backup when created without private keys:  
**Wallet** - payment.skey, stake.skey
**Pool**   - cold.skey

Example workflow for creating a wallet and pool

``` mermaid

sequenceDiagram
    Note over Offline: Create/Import a wallet
    Note over Offline: Create a new pool
    Note over Offline: Rotate KES keys to generate op.cert
    Note over Offline: Create a backup w/o private keys
    Offline->>Online: Transfer backup to online node
    Note over Online: Fund the wallet base address with enough Ada
    Note over Online: Register wallet using ' Wallet » Register ' in hybrid mode
    Online->>Offline: Transfer built tx file back to offline node
    Note over Offline: Use ' Transaction >> Sign ' with payment.skey from wallet to sign transaction
    Offline->>Online: Transfer signed tx back to online node
    Note over Online: Use ' Transaction >> Submit ' to send signed transaction to blockchain
    Note over Online: Register pool in hybrid mode
    loop
        Offline-->Online: Repeat steps to sign and submit built pool registration transaction
    end
    Note over Online: Verify that pool was successfully registered with ' Pool » Show '

```

##### Start CNTools in Online Mode
`$ ./cntools.sh`

You should get a screen that looks something like this:
```
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 >> CNTools vX.X.X - CONNECTED <<                    A Guild Operators collaboration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Main Menu

 ) Wallet      - create, show, remove and protect wallets
 ) Funds       - send, withdraw and delegate
 ) Pool        - pool creation and management
 ) Transaction - Witness, Sign and Submit a cold transaction (hybrid/offline mode)
 ) Metadata    - Post metadata on-chain (e.g voting)
 ) Blocks      - show core node leader slots
 ) Update      - update cntools script and library config files
 ) Backup      - backup & restore of wallet/pool/config
 ) Refresh     - reload home screen content
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                                                 Epoch 106 - 106h:14m:26s until next
 What would you like to do?                                         Node Sync: 14 :)

  [w] Wallet
  [f] Funds
  [p] Pool
  [t] Transaction
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
