??? example "One-Time major upgrade for Guild Scripts from 20-Jan-2023 (expand for details)"
    
    The scripts on guild-operators repository have gone through quite a few changes to accomodate for the below:

    - Replace `prereqs.sh` with `guild-deploy.sh` using minimalistic approach (i.e. anything you need to deploy is now required to be specified using command-line arguments). The old `prereqs.sh` is left as-is but will no longer be maintained.
    - Improve handling of environment variables for top level folder. Prior to this point, those who were using multiple deployments on same machine were required to have their session's environment set (for instance, using `prereqs.sh -t pvnode` would have created folder structure as `/opt/cardano/pvnode` and replaced `CNODE_HOME` references within scripts with `PVNODE_HOME`. This will no longer be required. The deriving of top level folder will be done relative to scripts folder. Thus, parent of the folder containing `env` file will automatically be treated as top level folder, and no longer depend on external environment variable. One may still use them for their own comfort to switch directories.
    - The above also helps for manual download of script from github as it will no longer require substituting `CNODE_HOME` references.
    - Consolidate binaries deployment to `"${HOME}"/.local/bin`. Previously, we could have had binaries deployed to various locations (`"${HOME}"/.cabal/bin` for node/CLI binaries, `"${HOME}"/.cargo/bin` for cncli binary, `"${HOME}"/bin` for downloaded binaries). This occured because of different compilers used different default locations for their output binariess (cargo for rust, cabal for Haskell, etc). The guild-deploy.sh/cabal-build-all.sh scripts will now provision the binaries to be made available to "${HOME}"/.local/bin instead. Ofcourse, as before, you can still customise the location of binaries using variables (eg: `CCLI`, `CNCLI`, `CNODE_HOME`) in `env` file.
    - Add option to download pre-compiled binaries instead of compiling them - and accordingly - options in `guild-deploy.sh`, giving users both the options.
    
    Some of the above required us to add breaking changes to some scripts, but hopefully the above explains the premise for those changes. To ease this one-time upgrade process for existing deployments,  we have tried to come up with the guide below, feel free to edit this file to improve the documents based on your experience. Again, apologies in advance to those who do not agree with the above changes (the old code would ofcourse remain unimpacted at tag `legacy-scripts`, so if you'd like to stick to old scripts , you can use `-b legacy-scripts` for your tools to switch back).  

### Steps for Ugrading

!!! warning
    Make sure you go through upgrade steps for your setup in a non-mainnet environment first!


- Download the latest `guild-deploy.sh` (checkout new syntax with `guild-deploy.sh -h`) to update all the scripts and files from the guild template. The scripts modified with user content (`env`, `gLiveView.sh`, `topologyUpdater.sh`, `cnode.sh`, etc) will be backed up before overwriting. The backed up files will be in the same folder as the original files, and will be named as *`${filename}_bkp<timestamp>`*. More static files (genesis files or some of the scripts themselves) will not be backed up, as they're not expected to be modified.

!!! warning "Remember"
    Please add any environment-specific parameters (eg: custom top level folder, network flag, etc) to the execution command below, similar to prereqs.sh (check new syntax using `guild-deploy.sh -h`)

- A basic (minimal) run of the guild-deploy script that will only update current scripts on mainnet using default paths:

``` bash
mkdir "$HOME/tmp";cd "$HOME/tmp"
curl -sS -o guild-deploy.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh
chmod 700 guild-deploy.sh
./guild-deploy.sh -s f -b master
```

- Source your bashrc file again , and ensure `"${HOME}"/.local/bin` is now part of your $PATH environment variable.

``` bash
source "${HOME}"/.bashrc
echo "${PATH}"
```

- Check and add back your customisations to config files (or simply restore from automatically created backup of your config/topology files).

- Since one of the basic changes we start to recommend as part of this revamp is moving your binaries to `"${HOME}"/.local/bin`, you would want to *move* the binaries below from current location:
    - "${HOME}"/.cabal/bin - Binaries built by `cabal build all` script (eg: `cardano-node`, `cardano-cli`, `bech32`, `cardano-address`, `cardano-submit-api`, `cardano-db-sync`
    - "${HOME}"/.cargo/bin - Binaries built by `cardano install` (eg: `cncli`)
    - "${HOME}"/bin - Downloaded binaries from previous `prereqs.sh` (eg: `cardano-hw-cli`)

You can move the binaries by using mv command (for example, if you dont have any other files in these folders, you can use the command below:

!!! note "Note"
    Ideally, you should shutdown services (eg: cnode, cnode-dbsync, etc) prior to running the below to ensure they run from new location (you can also re-deploy them if you haven't done so in a while, eg: `./cnode.sh -d`). At the end of the guide, you can start them back up.

``` bash
mv -t "${HOME}"/.local/bin/ "${HOME}"/.cabal/bin/* "${HOME}"/.cargo/bin/* "${HOME}"/bin/*
```

- We've found users often confuse between $PATH variable resolution between multiple shell sessions, systemd, etc. To avoid this, edit the following files and uncomment and set the following variables to the appropriate paths as per your deployment (eg: `CCLI="${HOME}"/.local/bin/cardano-cli` if following above):

    - env : CCLI, CNCLI, CNODEBIN
    - [If applicable] dbsync.sh: DBSYNCBIN
    - [If applicable] submitapi.sh: SUBMITAPIBIN
    - [If applicable] ogmios.sh: OGMIOSBIN

- The above should take care of tools and services. However, you might still have duplicate binaries in your $PATH (previous artifacts, re-build using old scripts, etc) - it is best that you remove any old binary files from alternate folders. You can do so by executing the below:

``` bash
whereis bech32 cardano-address cardano-cli cardano-db-sync cardano-hw-cli cardano-node cardano-submit-api cncli ogmios
```

The above might result in some lines having more than one entry (eg: you might have `cardano-cli` in `"${HOME}"/.cabal/bin` and `"${HOME}"/.local/bin`) - for which you'd want to delete the reference(s) not in `"${HOME}"/.local/bin` , while for other cases - you might have no values (eg: you may not use `cardano-db-sync`, `cncli`, `ogmios` and/or `cardano-hw-cli`. You need not take any actions for the binaries you do not use.

### Support/Improvements

Hope the guide above helps you with the migration, but again - we could've missed some edge cases. If so, please report via chat in [Guild Operators Support channel](https://t.me/guild_operators_official) only. Please DO NOT make edits to the script content based on forum/alternate guide/channels, while done with best intentions - there have been solutions put online that modify files unnecessarily instead of correcting configs and disabling updates, such actions will only cause trouble for future updates.
