### Steps for Upgrading

!!! danger "Change in config & logging starting node 10.5.x"
    Starting node 10.4.x, new cardano-tracer infrastructure was introduced for node , the use of this was disabled by default and thus - not as visible to users who may have missed the announcement. However, the legacy config/logging format has been said to be deprecated and could be retired in 10.6.x. Thus - we have shifted to minimum viable equivalent for newer config format.
    We are excluding setting up of cardano-tracer, as we feel it's an overkill for an average SPO. Please consult [official documentation](https://github.com/intersectmbo/cardano-node/blob/master/cardano-tracer/docs/cardano-tracer.md) if you'd like to run cardano-tracer.

    What this means, as a SPO:

      - You will no longer have EKG monitoring, there is equivalent SimplePrometheus backend available in node, which should suffice monitoring setup requirements.
      - The logging will not be sent to JSON file formats, but instead be available to stdout - we have updated all our references to include monitoring logs via journald (which allows electing JSON formats should one want to).
      - Since not only the log locations but also the formats of the logging have changed, we have to temporarily disable blockperf/logmonitor for now, as developers of corresponding tools will need to start from scratch reading newer log formats. This should not impact an average SPO not using those tools.
      - A side-effect change that got introduced is also to update logging for submitapi and dbsync configs to use stdout (thus, journald) instead of log files.

    Lastly, given the changes above, we **strongly** recommend you to make sure you go through upgrade steps for your setup in a non-mainnet environment first!!

While this guide is last updated when adding support for node 10.5.3, it is meant to serve as a generic reference point for typical upgrades.

- Download the latest `guild-deploy.sh` (always double check syntax of the script with `guild-deploy.sh -h`). The scripts modified with user content (`env`, `gLiveView.sh`, `topologyUpdater.sh`, `cnode.sh`, etc) will be backed up before overwriting. More static files (genesis, submitapi, etc or some of the scripts themselves) will not be backed up, as they're not expected to be modified.

!!! warning "Remember"
    You are expected to provide appropriate environment-specific parameters (eg: custom top level folder [-p], alternate name for top level folder [-t], network flag [-n], any additional components you use, etc) to the examples that pertain to your use case.

- Depending on node release, you may be able to simply perform an update-in-place of scripts and node, or for some cases, you may need to overwrite configs as well. Some Examples below:

    - Consider you're upgrading from 10.1.4 to 10.5.3, where config formats have changed. In this case, you'd want to overwrite your config files as well. You should follow changelog in node release notes to verify if you'd need to overwrite configs. Note that every time you do this, you may need to re-add your customisations - if any - to the relevant config files (typically - almost always, you'd have to update the topology.json when overwriting configs). There are backups created of original file in `"${CNODE_HOME}"/files` folder if you'd like to compare/reuse previous version.

      ``` bash
      mkdir "$HOME/tmp";cd "$HOME/tmp"
      curl -sfS -o guild-deploy.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh && chmod 700 guild-deploy.sh
      ./guild-deploy.sh -s dlfm -b master -n mainnet -t cnode -p /opt/cardano
      ```
    - A hopefully more common scenario would be where you dont need config changes (eg: 10.1.3 to 10.1.4), typical run of the guild-deploy script in this case would be to perform update in place of current scripts on mainnet and update binaries. In this scenario, no config files or user variables in scripts are overwritten. This is typically relevant on minor patch releases of node upgrade:

      ``` bash
      mkdir "$HOME/tmp";cd "$HOME/tmp"
      curl -sfS -o guild-deploy.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh && chmod 700 guild-deploy.sh
      ./guild-deploy.sh -s dlm -b master -n mainnet -t cnode -p /opt/cardano
      ```

!!! warning "Beware"
    When upgrading node, depending on node versions (especially for major release) - you'd likely have to wait for node to revalidate/replay ledger. This can take a few hours. Please always plan ahead, do it first on a relay to ensure you've got "${CNODE_HOME}/db" folder ready to copy over (while source and target node have been shutdown) - prior to starting on upgrade on new machine. If mithril for target node version is ready, you can also use [mithril-client](Scripts/mithril-client.md) to download snapshot instead of replaying, which may save you some time

- Once guild-deploy script has been run, source your bashrc file again (or restart session), and ensure `"${HOME}"/.local/bin` is part of your `$PATH` environment variable. If your shell does not auto-run bashrc, you may want to set it a call to "${HOME}"/.bashrc in your `.profile`

``` bash
source "${HOME}"/.bashrc
echo "${PATH}"
```

### Troubleshooting {: #troubleshooting}

- We've found users often confuse between `$PATH` variable resolution between multiple shell sessions, systemd, etc. While if you only used this guide, the binaries should be in `"${HOME}/.local/bin"`, you may have manually downloaded to another location before. To avoid this, you can edit the following files and uncomment and set the following variables to the appropriate paths as per your deployment (eg: `CCLI="${HOME}"/.local/bin/cardano-cli` if following above):

    - env : CCLI, CNCLI, CNODEBIN
    - [If applicable] dbsync.sh: DBSYNCBIN
    - [If applicable] submitapi.sh: SUBMITAPIBIN
    - [If applicable] ogmios.sh: OGMIOSBIN

- The above should take care of tools and services. However, you might still have duplicate binaries in your `$PATH` (previous artifacts, re-build using old scripts, etc) - it is best that you remove any old binary files from alternate folders. You can do so by executing the below:

``` bash
whereis bech32 cardano-address cardano-cli cardano-db-sync cardano-hw-cli cardano-node cardano-submit-api cncli ogmios
```

For some cases - you might have no values (eg: you may not use `cardano-db-sync`, `cncli`, `ogmios` and/or `cardano-hw-cli`. You need not take any actions for the binaries you do not use.

- If you are having trouble connecting to node post upgrade from gLiveView, typically the first issue you'd want to eliminate is  whether you missed that node might need ledger replay/revalidation (which could take hours as indicated earlier on the page). You can check the node status via `sudo systemctl status cnode`. If the node shows as up, you can monitor logs via `sudo journalctl -xeu cnode.service -f`. If you're unable to start node using systemd itself, use the same command above and scroll back until you see a startup attempt with reason (typically this could be a couple of pages back).

### Unintended update-in-place {: #unintended}

Let's say you accidentally did an update of the files that you didnt intend to and want to revert all your scripts to previous state. While you have the backups of the scripts created while doing in-place update, you can always make use of branch flag that most scripts that perform update-in-place provide (eg: for gLiveView.sh that you want to restore to 10.1.4 state), this would be `-b node-10.1.4`. The available tags that can be used can be visited [here](https://github.com/cardano-community/guild-operators/tags).

### Support/Improvements {: #support}

Hope the guide above helps you with the migration, but again - we could've missed some edge cases. If so, please report via chat in [Koios Discussions channel](https://t.me/CardanoKoios) or open an issue on github. Please DO NOT make edits to the script content based on forum/alternate guide/channels, while done with best intentions - there have been solutions put online that modify files unnecessarily instead of correcting configs and disabling updates, such actions will only cause trouble for future updates.
