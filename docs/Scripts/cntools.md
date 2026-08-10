!!! important

    - Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.
    - The active testers for this script use Fedora/CentOS/RHEL/Ubuntu operating systems, other OS may require customisations.
    - The tool uses the folder structure defined [here](../basics.md#folder-structure). Everyone is free to customise, but while doing so beware that you may introduce changes that may not be tested during updates.
    - Always use Preview/Preprod/Guild network first to familiarise, read the warning/messages in full, maintain your keys/backups with passwords (no one other than yourself can retrieve the funds if you make an accident), before performing actions on mainnet.

Koios CNTools is like a swiss army knife for pool operators to simplify typical operations regarding their wallet keys and pool management. Please note that this tool only aims to simplify usual tasks for its users, but it should **NOT** act as an excuse to skip understanding how to manually work through things or basics of Linux operations. The skills highlighted on the [home page](../index.md) are paramount for a stake pool operator, and so is the understanding of configuration files and network. Please ensure you've read and understood the disclaimers **before** proceeding.

!!! warning "Node implementation support"
    CNTools is supported with cnode and deployed for experimental Dingo
    evaluation on `preprod` and `preview`. Dingo exposes a standard
    cardano-cli-compatible node-to-client socket, but it is not a production
    or mainnet target. CNCLI block logs and other cnode-only integrations do
    not become available merely because CNTools is installed. Amaru does not
    install CNTools because it lacks the required compatible local interface.

Visit the [Changelog](cntools-changelog.md) section to see progress and current release.

#### Overview
The tool consists of two CNTools-specific files:

- `cntools.sh` - the main script to launch cntools.
- `cntools.library` - internal script with helper functions.

In addition to those files, CNTools depends on the common [`env`](env.md)
entrypoint and its runtime libraries. CNTools connects to the node through the
`env` file in the same directory. Customize `env` and `cntools.sh` only where
their User Variables sections require it.

On Dingo, `env` selects `$HOME/.local/bin/cardano-cli-dingo` and
`$NODE_HOME/sockets/dingo.socket` automatically. The CLI is pinned in Dingo's
own release manifest and does not replace cnode's `cardano-cli`. Set `CCLI`
explicitly in `env` only when intentionally using another reviewed CLI build.

Supplying `-b <branch>` asks the installed dispatcher to apply a complete
transaction from that branch and then records its exact source in
`${NODE_HOME}/.deployment.json`; CNTools no longer creates or reads
`scripts/.env_branch`.

Additionally, CNTools can integrate and enable optional functionalities based on external components:

- `cncli.sh` is a companion script with optional functionalities to run on the core node (block producer) such as monitoring created blocks, calculating leader schedules and block validation.
- `logMonitor.sh` historically complemented `cncli.sh`, but it is currently
  disabled because it does not parse the current cnode tracing format.
- On cnode, Catalyst operations install the pinned, checksum-verified
  `catalyst-toolbox` selected by
  `${NODE_HOME}/files/cnode-release.json`; CNTools no longer downloads an
  unversioned executable directly into `$HOME/.local/bin`. An existing binary
  is retained only when both its reported version and checksum match that
  policy; otherwise CNTools replaces it with the reviewed artifact. This
  cnode-specific companion policy is not available in the Dingo profile.

See [CNCLI](cncli.md) and [Log Monitor](logmonitor.md) for details.

Koios CNTools can operate in following modes:

- Online - The default mode using either a local node or Koios API to query the blockchain.
  - Local `-n` - The local node is used to query the blockchain for needed data. This is the default mode when you start CNTools without parameters.
  - Light `-l` - Koios query layer is used and removes the need for a local node deployment. This mode is both quicker and lighter on resources but comes with a third party dependency.
- Hybrid - When running in online mode, this option can be used in menus to create offline transaction files that can be passed to Offline CNTools to sign.
- Offline `-o` - Launches CNTools with a limited set of features. This mode **does not require access to cardano-node or access to an internet connection**. It is mainly used to create Wallet/Pool and access `Transaction >> Sign` to sign an offline transaction file created in Hybrid mode.
- Advanced `-a` - Exposes a new `Advanced` menu, which allows users to manage (create/mint/burn) new assets.

In addition to above mentioned runtime arguments to launch CNTools in different modes, it can also be persisted by editing User Variables section within `cntools.sh` script.

```text
Usage: cntools.sh [-n|-l|-o] [-a] [-u] [-b <branch name>] [-v]

-n    Local mode (default)
-l    Light mode using Koios without a local node
-o    Offline/air-gapped mode with limited functionality
-a    Enable advanced/developer features
-u    Skip the script update check
-b    Request a complete payload update from an alternate Guild branch
-v    Print the CNTools version
```

#### Download and Update
CNTools can check for updates, but it no longer downloads only CNTools files.
The check delegates to the installed `guild-deploy.sh`, which validates and
updates the complete source-receipted Guild payload as one transaction. A
selected branch or tag must resolve and never silently falls back to `master`.

Automatic refresh cannot reproduce a deployment made from a local or dirty
checkout. In that case, re-run the dispatcher explicitly with
`-S local -L <checkout>` and add `-D` again only when the checkout is
intentionally dirty.
For breaking changes, follow the post-upgrade prompts; if stuck, re-run the
current dispatcher before proceeding.

!!! info ""
    If you have not updated in a while, it is possible that you might come from a release with breaking changes. If so, please be sure to check out the [upgrade](../upgrade.md) instructions.

#### Navigation
The scripts menu supports both arrow key navigation and shortcut key selection. The character within the square brackets is the shortcut to press for quick navigation. For other selections like wallet and pool menu that don't contain shortcuts, there is a third way to navigate. Key pressed is compared to the first character of the menu option and if there is a match the selection jumps to this location. A handy way to quickly navigate a large menu. 

#### Hardware Wallet
CNTools includes hardware wallet support since version `7.0.0` through Vacuumlabs `cardano-hw-cli` application. Initialize and update firmware/app on the device to the latest version before usage following the manufacturer instructions.

To enable hardware support run `guild-deploy.sh -s w`. This downloads and
installs Vacuumlabs `cardano-hw-cli`, including `udev` configuration. The
release selector is controlled by `${NODE_HOME}/files/cnode-release.json` and
may be `latest` or a pinned version. Run the same command again to resolve and
install the configured policy. For additional deployment options, run
`guild-deploy.sh -h`.

=== "Ledger"

    - Supported devices: Nano S / Nano X  
    - Make sure the latest cardano app is installed on the device.

=== "Trezor"

    - Supported devices: Model T  
    - Install current firmware and follow Trezor Suite's device-connectivity
      guidance. Trezor has
      [deprecated the standalone Trezor Bridge](https://trezor.io/guides/trezor-suite/deprecation-and-removal-of-standalone-trezor-bridge)
      and recommends removing a separate Bridge installation because it can
      interfere with newer releases. CNTools may still display an older Bridge
      reminder; do not use its retired download URL.

#### Offline Workflow

CNTools can be run in online and offline mode. At a very high level, for working with offline devices, remember that you need to use CNTools in an online node to generate a staging transaction for the desired type of transaction, and then move the staging transaction to an offline node to sign (authorize) using the signing keys on your offline node - and then bring back the signed transaction to the online node for submission to the chain. 

For the offline workflow, all the wallet and pool keys should be kept on the offline node. The backup function in CNTools has an option to create a backup without private keys (sensitive signing keys) to be transferred to online node. All other files are included in the backup to be transferred to the online node. 

Keys excluded from backup when created without private keys:
**Wallet** - `payment.skey`, `stake.skey`
**Pool**   - `cold.skey`

Setting up an offline server requires solid system-administration experience:
you must provide offline package mirrors, transfer files safely, and understand
the deployment layout. `guild-deploy.sh` is not expected to run without
network access. The safest preparation is to transfer a current deployment
skeleton without private online keys, including the common runtime, selected
adapter, release metadata, and companion tools required by the workflow. A
cnode offline host needs compatible `cardano-node`, `cardano-cli`, `bech32`,
and `cardano-address` executables. A Dingo-derived skeleton selects
`cardano-cli-dingo`; optional wallet-import or hardware features still require
their external companion tools. Both need runtime commands such as `jq`, `bc`,
and GNU core utilities. Practice the complete workflow on preview, preprod, or
Guild before mainnet; Dingo itself remains testnet-only.

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
     >> Koios CNTools vX.X.X - Guild - CONNECTED <<
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     Main Menu    Telegram Announcement / Support channel: t.me/CardanoKoios/9759
    
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
     >> Koios CNTools vX.X.X - Guild - OFFLINE <<
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     Main Menu    Telegram Announcement / Support channel: t.me/CardanoKoios/9759
    
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
