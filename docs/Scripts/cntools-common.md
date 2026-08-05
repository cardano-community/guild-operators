!!! warning "Node support"
    These workflows are supported by cnode and available for experimental
    testing with Dingo on `preprod` and `preview`. Dingo is not a production or
    mainnet target. Amaru does not install CNTools because it does not provide
    the required compatible local-node interface.

!!! important
    Familiarize yourself with the Online workflow of creating wallets and pools on the Preview/Preprod/Guild network first. You can then move on to test the [Offline Workflow](../Scripts/cntools.md#offline-workflow). The Offline workflow means that the private keys never touch the Online node. When comfortable with both the online and offline CNTools workflow, it's time to deploy what you learnt on the mainnet.

This chapter describes some common use-cases for wallet and pool creation when running CNTools in Online mode. CNTools contains much more functionality not described here.

=== "Create Wallet"

    A wallet is needed for pledge and to pay for pool registration fee.

    1. Choose `[w] Wallet` and you will be presented with the following menu:
      ```
      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
       >> WALLET
      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
       Wallet Management
      
       ) New         - create a new wallet
       ) Import      - import a 24/15-word mnemonic or Ledger/Trezor HW wallet
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
    2. Choose `[n] New` to create a new wallet. `[i] Import` can also be used to import a Daedalus/Yoroi based 15 or 24 word wallet seed  
    3. Give the wallet a name  
    4. CNTools will give you the wallet address.  For example:
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
    5. Send some money to this wallet. Either through the faucet or have a friend send you some.
    
    !!! info ""
        - The wallet must have funds in it before you can proceed.
        - The Wallet created from here is not derived from mnemonics, please use next tab if you'd like to use a wallet that can also be accessed from Daedalus/Yoroi

=== "Import Daedalus/Yoroi/HW Wallet"

    The `Import` feature of CNTools is originally based on [this guide](https://gist.github.com/ilap/3fd57e39520c90f084d25b0ef2b96894) from [Ilap](https://github.com/ilap).
    
    If you would like to use `Import` to import a 15- or 24-word wallet seed,
    ensure that `cardano-address` and `bech32` binaries are available in
    `$PATH`:
      ```
      bech32 --version
      <installed version>

      cardano-address --version
      <installed version>
      ```
    !!! info ""
        Both executables must be present, but the example does not require a
        particular old version. Run the current `guild-deploy.sh -s d` to
        install the checksum-verified cnode binary and companion set selected
        by `cnode-release.json`.

    To import a Daedalus/Yoroi wallet to CNTools, open CNTools and select the `[w] Wallet` option, and then select the `[i] Import`, the following menu will appear:
      ```
      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
       >> WALLET >> IMPORT
      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
       Wallet Import
      
       ) Mnemonic  - Daedalus/Yoroi 24 or 25 word mnemonic
       ) HW Wallet - Ledger/Trezor hardware wallet
      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
       Select Wallet operation
      
        [m] Mnemonic
        [w] HW Wallet
        [h] Home
      ```
    !!! info "Note"
        You can import Hardware wallet using `[w] HW Wallet` above, but please note that before you are able to use hardware wallet in CNTools, you need to ensure you can detect your hardware device at OS level using `cardano-hw-cli`
    
    Select the wallet you want to import, for Daedalus / Yoroi wallets select `[m] Mnemonic`:
      ```
      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
       >> WALLET >> IMPORT >> MNEMONIC
      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      
      Name of imported wallet: TEST
      
      24 or 15 word mnemonic(space separated):
      ```
    Give your wallet a name (in this case `TEST`) and enter your mnemonic
    phrase. **Read** all notes presented by CNTools before proceeding.

=== "Create Pool"
    Create the necessary pool keys.
    
    1. From the main menu select `[p] Pool`
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
    2. Select `[n] New` to create a new pool  
    3. Give the pool a name. In our case, we call it TEST. The result should look something like this:
      ```
      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
       >> POOL >> NEW
      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      
      Pool Name: TEST
      
      Pool: TEST
      ID (hex)    : 8d5a3510f18ce241115da38a1b2419ed82d308599c16e98caea1b4c0
      ID (bech32) : pool134dr2y833n3yzy2a5w9pkfqeakpdxzzenstwnr9w5x6vqtnclue
      ```
    
=== "Register Pool"
    Register the pool on-chain.
    
    1. From the main menu select `[p] Pool`  
    2. Select `[r] Register`  
    3. Select the pool you just created  
    4. CNTools will give you prompts to set pledge, margin, cost, metadata, and relays. Enter values that are useful to you.  
    
    !!! info ""
        Make sure you set your pledge low enough to insure your funds in your wallet will cover pledge plus pool registration fees.  
    
    5. Select wallet to use as pledge wallet, `Test` in our case. As this is a newly created wallet, you will be prompted to continue with wallet registration. When complete and if successful, both wallet and pool will be registered on-chain.
    
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
      
      Enter Pool's JSON URL to host metadata file - URL length should be less than 128 chars (default: https://foo.bat/poolmeta.json):
      
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
      
      Please host file /opt/cardano/cnode/priv/pool/TEST/poolmeta.json as-is at https://foo.bat/poolmeta.json
      
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
      
      Register a multi-owner pool (you need to have stake.vkey of any additional owner in a separate wallet folder under $CNODE_HOME/priv/wallet)?
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
    
    6. As mentioned in the above output: *Uncomment and set value for `POOL_NAME` in `./env` with 'TEST'* (in our case, the `POOL_NAME` is `TEST`). The `cnode.sh` script will automatically detect whether the files required to run as a block producing node are present in the `$CNODE_HOME/priv/pool/<POOL_NAME>` directory.
    
=== "Rotate KES Keys"
    The node runs with an operational certificate generated using the KES hot
    key. Rotate the KES key before that certificate expires or the node cannot
    forge valid blocks. Expiry is derived from `slotsPerKESPeriod` and
    `maxKESEvolutions` in the network's Shelley genesis; current mainnet
    parameters are 62 periods of 36 hours, or roughly 93 days. The cold-key
    files (`cold.skey`, `cold.vkey`, and `cold.counter`) must be present on the
    machine where CNTools performs the rotation.

    1. To Rotate KES keys and generate the operational certificate - `op.cert`.
    
      *  From the main menu select `[p] Pool`  
      *  Select `[o] Rotate`  
      *  Select the pool you just created  

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
    
    2. Start or restart your `cardano-node`. For a
       [systemd deployment](../Build/node-cli.md#systemd), derive the unit name
       from the deployment manifest:

       ```bash
       CNODE_SERVICE="$(jq -er '.serviceName' \
         "$CNODE_HOME/.deployment.json")"
       sudo systemctl restart "${CNODE_SERVICE}.service"
       ```

    3. Ensure the node is running as a block producing (core) node.
    
    You can use [gLiveView](gliveview.md). Its header should identify
    `[cardano-node]`, the `Core` role, and the expected network.
    
    Alternatively, follow the systemd journal and look for current forge
    traces such as `Forge.Loop.StartLeadershipCheck` and
    `Forge.Loop.NodeNotLeader`:

    ```bash
    CNODE_SERVICE="$(jq -er '.serviceName' \
      "$CNODE_HOME/.deployment.json")"
    sudo journalctl -fu "${CNODE_SERVICE}.service"
    ```
