### Steps for Upgrading

!!! warning
    Make sure you go through upgrade steps for your setup in a non-mainnet environment first!!


- Download the latest `guild-deploy.sh` (always double check syntax of the script with `guild-deploy.sh -h`). The scripts modified with user content (`env`, `gLiveView.sh`, `topologyUpdater.sh`, `cnode.sh`, etc) will be backed up before overwriting. The backed up files will be in the same folder as the original files, and will be named as *`${filename}_bkp<timestamp>`*. More static files (genesis files or some of the scripts themselves) will not be backed up, as they're not expected to be modified.

!!! warning "Remember"
    You are expected to provide appropriate environment-specific parameters (eg: custom top level folder [-p], alternate name for top level folder [-t], network flag [-n], etc) to the examples that pertain to your use case

- Depending on node release, you may be able to simply perform an update-in-place of scripts and node, or for some cases, you may need to overwrite configs as well. Some Examples below:

    - A typical run of the guild-deploy script that will perform update in place of current scripts on mainnet and update binaries (alongwith re-compiling libsodium dependencies). In this scenario no config files or user variables in scripts are overwritten. This is typically relevant on minor patch releases of node upgrade:

      ``` bash
      mkdir "$HOME/tmp";cd "$HOME/tmp"
      curl -sfS -o guild-deploy.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh && chmod 700 guild-deploy.sh
      ./guild-deploy.sh -s dl -b master -n mainnet -t cnode -p /opt/cardano
      ```

    - Another scenario would be when you're required to overwrite configs (eg: node-8.1.2 to node-9.1.0 introduced change in genesis/config/topology file formats). In this case, you'd want to overwrite your config files as well. You should follow changelog in node release notes to verify if you'd need to overwrite configs. Note that every time you do this, you may need to re-add your customisations - if any - to the relevant config files (typically - almost always, you'd have to update the topology.json when overwriting configs). There are backups created of original file in `"${CNODE_HOME}"/files` folder if you'd like to compare/reuse previous version.

      ``` bash
      mkdir "$HOME/tmp";cd "$HOME/tmp"
      curl -sfS -o guild-deploy.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh && chmod 700 guild-deploy.sh
      ./guild-deploy.sh -s dlf -b master -n mainnet -t cnode -p /opt/cardano
      ```

!!! warning "Beware"
    When upgrading node, depending on node versions (especially for major release) - you'd likely have to wait for node to revalidate/replay ledger. This can take a few hours. Please always plan ahead, do it first on a relay to ensure you've got "${CNODE_HOME}/db" folder ready to copy over (while source and target node have been shutdown) - prior to starting on upgrade on new machine. If mithril for target node version is ready, you can also use [mithril-client](Scripts/mithril-client.md) to download snapshot instead of replaying, which may save you some time

- Once guild-deploy script has been run, source your bashrc file again (or restart session), and ensure `"${HOME}"/.local/bin` is part of your $PATH environment variable. If your shell does not auto-run bashrc, you may want to set it a call to "${HOME}"/.bashrc in your `.profile`

``` bash
source "${HOME}"/.bashrc
echo "${PATH}"
```

### Troubleshooting {: #troubleshooting}

- We've found users often confuse between $PATH variable resolution between multiple shell sessions, systemd, etc. While if you only used this guide, the binaries should be in "${HOME}/.local/bin", you may have manually downloaded to another location before. To avoid this, you can edit the following files and uncomment and set the following variables to the appropriate paths as per your deployment (eg: `CCLI="${HOME}"/.local/bin/cardano-cli` if following above):

    - env : CCLI, CNCLI, CNODEBIN
    - [If applicable] dbsync.sh: DBSYNCBIN
    - [If applicable] submitapi.sh: SUBMITAPIBIN
    - [If applicable] ogmios.sh: OGMIOSBIN

- The above should take care of tools and services. However, you might still have duplicate binaries in your $PATH (previous artifacts, re-build using old scripts, etc) - it is best that you remove any old binary files from alternate folders. You can do so by executing the below:

``` bash
whereis bech32 cardano-address cardano-cli cardano-db-sync cardano-hw-cli cardano-node cardano-submit-api cncli ogmios
```

For some cases - you might have no values (eg: you may not use `cardano-db-sync`, `cncli`, `ogmios` and/or `cardano-hw-cli`. You need not take any actions for the binaries you do not use.

- If you are having trouble connecting to node post upgrade from gLiveView, typically the first issue you'd want to eliminate is  whether you missed that node might need ledger replay/revalidation (which could take hours as indicated earlier on the page). You can check the node status via `sudo systemctl status cnode`. If the node shows as up, you can monitor logs via `tail -100f "${CNODE_HOME}/logs/node.json`. If you're unable to start node using systemd itself, you can check the systemd output via `sudo journalctl -xeu cnode.service` and scroll back until you see a startup attempt with reason (typically this could be a couple of pages back). If nothing obvious (eg: showing files used as `/files/config.json` instead of `$CNODE_HOME/files/config.json` )comes up from there, you'd want to view node logs to see if there is something recorded in `node.json` instead.

### Unintended update-in-place {: #unintended}

Let's say you accidentally did an update of the files that you didnt intend to and want to revert all your scripts to previous state. While you have the backups of the scripts created while doing in-place update, you can always make use of branch flag that most scripts that perform update-in-place provide (eg: for gLiveView.sh that you want to restore to 8.1.2 state), this would be `-b node-8.1.2`. The available tags that can be used can be visited [here](https://github.com/cardano-community/guild-operators/tags)

### Support/Improvements {: #support}

Hope the guide above helps you with the migration, but again - we could've missed some edge cases. If so, please report via chat in [Koios Discussions channel](https://t.me/CardanoKoios) or open an issue on github. Please DO NOT make edits to the script content based on forum/alternate guide/channels, while done with best intentions - there have been solutions put online that modify files unnecessarily instead of correcting configs and disabling updates, such actions will only cause trouble for future updates.
