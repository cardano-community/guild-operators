!!! important

    - Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.
    - The active testers for this script use Fedora/CentOS/RHEL/Ubuntu operating systems, other OS may require customisations.
    - The tool uses the folder structure defined [here](../basics.md#folder-structure). Everyone is free to customise, but while doing so beware that you may introduce changes that may not be tested during updates.
    - Always use Testnet/Guild network first to familiarise, read the warning/messages in full, maintain your keys/backups with passwords (no one other than yourself can retrieve the funds if you make an accident), before performing actions on mainnet.

CNTools is like a swiss army knife for pool operators to simplify typical operations regarding their wallet keys and pool management. Please note that this tool only aims to simplify usual tasks for its users, but it should **NOT** act as an excuse to skip understanding how to manually work through things or basics of Linux operations. The skills highlighted on the [home page](../index.md) are paramount for a stake pool operator, and so is the understanding of configuration files and network. Please ensure you've read and understood the disclaimers **before** proceeding.

Visit the [Changelog](../Scripts/cntools-changelog.md) section to see progress and current release.

#### Overview
The tool consist of three files.  

- `cntools.sh` - the main script to launch cntools.
- `cntools.library` - internal script with helper functions.

In addition to the above files, there is also a dependency on the common [`env`](../Scripts/env.md) file. CNTools connects to your node through the configuration in the `env` file located in the same directory as the script. Customize `env` and `cntools.sh` files to your needs.

Additionally, CNTools can integrate and enable optional functionalities based on external components:

- `cncli.sh` is a companion script with optional functionalities to run on the core node (block producer) such as monitoring created blocks, calculating leader schedules and block validation.
- `logMonitor.sh` is another companion script meant to be run together with the `cncli.sh` script to give a more complete picture.

See [CNCLI](../Scripts/cncli.md) and [Log Monitor](../Scripts/logmonitor.md) sections for more details.

CNTools can operate in following modes:

- Advanced - When CNTools is launched with `-a` runtime argument, this launches CNTools exposing a new `Advanced` menu, which allows users to manage (create/mint/burn) new assets.
- Online - When all wallet and pool keys are available on the hot node, use this option. This is the default mode when you start CNTools without parameters.
- Hybrid - When running in online mode, this option can be used in menus to create offline transaction files that can be passed to Offline CNTools to sign.
- Offline - When CNTools is launched with `-o` runtime argument, this launches CNTools with limited set of features. This mode **does not require access to cardano-node**. It is mainly used to create Wallet/Pool and access `Transaction >> Sign` to sign an offline transaction file created in Hybrid mode.

#### Download and Update
The update functionality is provided from within CNTools. In case of breaking changes, please follow the prompts post-upgrade. If stuck, it's always best to re-run the latest `prereqs.sh` before proceeding.

!!! info ""
    If you have not updated in a while, it is possible that you might come from a release with breaking changes. If so, please be sure to check out the [upgrade](../upgrade.md) instructions.

#### Navigation
The scripts menu supports both arrow key navigation and shortcut key selection. The character within the square brackets is the shortcut to press for quick navigation. For other selections like wallet and pool menu that don't contain shortcuts, there is a third way to navigate. Key pressed is compared to the first character of the menu option and if there is a match the selection jumps to this location. A handy way to quickly navigate a large menu. 

#### Hardware Wallet
CNTools include hardware wallet support since version `7.0.0` through Vacuumlabs `cardano-hw-cli` application. Initialize and update firmware/app on the device to the latest version before usage following the manufacturer instructions.

To enable hardware support run `prereqs.sh -w`. This downloads and installs Vacuumlabs `cardano-hw-cli` including `udev` configuration. When a new version of Vacuumlabs `cardano-hw-cli` is released, run `prereqs.sh -w` again to update. For additional runtime options, run `prereqs.sh -h`.

=== "Ledger"

    - Supported devices: Nano S / Nano X  
    - Make sure the latest cardano app is installed on the device.

=== "Trezor"

    - Supported devices: Model T  
    - Make sure the latest firmware is installed on the device. In addition to this, install `Trezor Bridge` for your system before trying to use your Trezor device in CNTools. You can find the latest version of the bridge at https://wallet.trezor.io/#/bridge

#### Offline Workflow

CNTools can be run in online and offline mode. At a very high level, for working with offline devices, remember that you need to use CNTools in an online node to generate a staging transaction for the desired type of transaction, and then move the staging transaction to an offline node to sign (authorize) using the signing keys on your offline node - and then bring back the signed transaction to the online node for submission to the chain. 

For the offline workflow, all the wallet and pool keys should be kept on the offline node. The backup function in CNTools has an option to create a backup without private keys (sensitive signing keys) to be transferred to online node. All other files are included in the backup to be transferred to the online node. 

Keys excluded from backup when created without private keys:
**Wallet** - `payment.skey`, `stake.skey`
**Pool**   - `cold.skey`

Note that setting up an offline server requires good SysOps background (you need to be aware of how to set up your server with offline mirror repository, how to transfer files across and be fairly familiar with the disk layout of guild tools). The `prereqs.sh` in its current state is not expected to run on an offline machine. Essentially, you simply need the `cardano-cli`, `bech32`, `cardano-address` binaries in your `$PATH`, OS level dependency packages [`jq`, `coreutils`, `pkgconfig`, `gcc-c++` and `bc` ], and perhaps a copy from your online `cnode` directory (to ensure you have the right `genesis`/`config` files on your offline server). We strongly recommend you to familiarise yourself with the workflow on the testnet / guild networks first, before attempting on mainnet.

Example workflow for creating a wallet and pool:

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

=== "Online mode"

    To start CNTools in Online (advanced) Mode, execute the script from the `$CNODE_HOME/scripts/` directory:
    ```
    cd $CNODE_HOME/scripts
    ./cntools.sh -a
    ```

    You should get a screen that looks something like this:

    ```
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     >> CNTools vX.X.X - Guild - CONNECTED <<            A Guild Operators collaboration
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     Main Menu    Telegram Announcement / Support channel: t.me/guild_operators_official
    
     ) Wallet      - create, show, remove and protect wallets
     ) Funds       - send, withdraw and delegate
     ) Pool        - pool creation and management
     ) Transaction - Sign and Submit a cold transaction (hybrid/offline mode)
     ) Blocks      - show core node leader schedule & block production statistics
     ) Backup      - backup & restore of wallet/pool/config
     ) Advanced    - Developer and advanced features: metadata, multi-assets, ...
     ) Refresh     - reload home screen content
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                                                      Epoch 276 - 3d 19:08:27 until next
     What would you like to do?                                         Node Sync: 12 :)
    
      [w] Wallet
      [f] Funds
      [p] Pool
      [t] Transaction
      [b] Blocks
      [u] Update
      [z] Backup & Restore
      [a] Advanced
      [r] Refresh
      [q] Quit
    ```

=== "Offline mode"

    To start CNTools in Offline Mode, execute the script from the `$CNODE_HOME/scripts/` directory using the `-o` flag:
    ```
    cd $CNODE_HOME/scripts
    ./cntools.sh -o
    ```
    
    The main menu header should let you know that node is started in offline mode:
    ```
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     >> CNTools vX.X.X - Guild - OFFLINE <<              A Guild Operators collaboration
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     Main Menu    Telegram Announcement / Support channel: t.me/guild_operators_official
    
     ) Wallet      - create, show, remove and protect wallets
     ) Funds       - send, withdraw and delegate
     ) Pool        - pool creation and management
     ) Transaction - Sign and Submit a cold transaction (hybrid/offline mode)
    
     ) Backup      - backup & restore of wallet/pool/config
    
     ) Refresh     - reload home screen content
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                                                      Epoch 276 - 3d 19:03:46 until next
     What would you like to do?
    
      [w] Wallet
      [f] Funds
      [p] Pool
      [t] Transaction
      [z] Backup & Restore
      [r] Refresh
      [q] Quit
    ```
