### Moving to per-deployment binaries {: #per-deployment-binaries}

Each deployment now keeps its binaries in its own `${NODE_HOME}/bin`, instead of
sharing `~/.local/bin` with every other deployment of the OS user. Deploying one
network can no longer change what another one runs, including `gum` and
`cardano-hw-cli`.

Moving an existing deployment takes one run of the current `guild-deploy.sh`, with
your usual `-n`, `-t` and `-p` values. Download it first, because an older copy
can't do this. Check what it would do. This changes nothing:

``` bash
./guild-deploy.sh -C -n mainnet -t cnode -p /opt/cardano
```

Then deploy, and restart the node when you choose to:

``` bash
./guild-deploy.sh -s d -n mainnet -t cnode -p /opt/cardano
```

``` bash
sudo systemctl restart cnode
```

The running node isn't touched. The new version takes effect when you restart it,
and a major upgrade can replay the ledger for several hours, so test on a relay
first.

**What the deployment does for you.** Tools you already have, such as `cncli`, are
copied into `bin` unchanged. If you leave out `-s d` and your versions are already
new enough, all your binaries are copied unchanged and no restart is needed.
`~/.local/bin` is never changed. The run lists any old copies this deployment no
longer uses, and when it's safe to remove them.

It also removes group and other write access from the folders and files under
`priv`, because CNTools now refuses to work with them otherwise. Read access is left
as it is.

**When it stops.** It checks first, and a stop leaves the deployment exactly as it
was. It stops, and says what to do, when:

- your node or CLI is older than the new scripts need and you left out `-s d`. New
  scripts on an old node would work until the next restart, and then the node
  wouldn't start
- `CNODEBIN` or `CCLI` in `env` points at a binary that's too old
- the deployment has a chain database, but this OS user has no `cardano-node`
- the target isn't writable, is low on disk, or can't run programs (a `noexec` mount)
- a Dingo or Amaru deployment still has its binaries in `~/.local/bin` and you left
  out `-s d`

**Commands typed by hand.** Guild scripts and services find their binaries without
any change. For commands you type yourself, select the deployment in that shell.
This also sets the socket and network, and sourcing another deployment's copy
switches to it:

``` bash
source /opt/cardano/cnode/scripts/activate
```

Without it, a migrated user's plain `cardano-cli` still runs the old copy in
`~/.local/bin` until you remove it. A new deployment has no copy there, so the
command isn't found.

**Units that still use the old path.** The run lists any that do. For example, an
existing Mithril signer keeps running from `~/.local/bin` until you regenerate its
unit and environment with `mithril-signer.sh -d`.

**To undo a copy,** rename the folder and the deployment returns to the shared
files. This doesn't apply after `-s d`, because the old binaries would be below the
new minimum:

``` bash
mv /opt/cardano/cnode/bin /opt/cardano/cnode/bin.disabled
```

!!! danger "Older scripts stop working until you migrate"
    Older helper scripts check for updates when they start, and exit when they
    can't find the old file path. Once this release is on `master`, on a deployment
    that hasn't migrated:

    - gLiveView, CNTools, the Mithril helper scripts and older copies of
      `blockPerf.sh` and `topologyUpdater.sh` exit at startup
    - CNCLI services fail at their next restart, because their units don't skip the
      check
    - the node, db-sync, the submit API and Ogmios keep running and restarting, as
      they have no update check

    Migrate as above to fix this. To keep the old scripts working until you can, set
    this in the deployment's `scripts/env`:

    ``` bash
    UPDATE_CHECK="N"
    ```

### Steps for Upgrading

!!! important "Deployment metadata and service migration"
    Run the current `guild-deploy.sh` before accepting individual helper-script
    updates on an older flat cnode installation. The former cnode-specific
    helper URLs are retired, so an old updater will fail safely without
    replacing its local file. The deployment entrypoint installs the complete
    shared runtime and manifest in one operation.

    The common deployment entrypoint now accepts
    `-i cnode|dingo|amaru`; omitting it still selects `cnode`. Existing cnode
    operators should keep their current `-p`, `-t`, and `-n` values on the
    first run. A successful run creates `.deployment.json` at the deployment
    root (normally `${CNODE_HOME}` for cnode),
    imports the branch from the former `scripts/.env_branch`, and archives
    that sidecar. Subsequent `-b` updates are stored in the manifest.
    Manifest-backed runtime helpers never choose a different branch on their
    own. Guild-deploy retains its visible fallback to `master`, but only after
    Git confirms that the recorded branch or tag no longer exists; clone or
    verification errors stop instead. For a new Dingo or Amaru deployment,
    `-n preprod` or `-n preview` is required. Later dispatcher runs may omit
    `-n` because the valid manifest restores the network.

    cnode now uses the same repository structure as the alternate profiles:
    release metadata is installed from
    `files/node-implementations/cnode/release.json`, and network templates are
    read from `files/configs/cnode/<network>`. Older Guild Operators tags retain
    the previous paths for deliberately tagged deployments. The current
    profile verifies the pinned cardano-node and cardano-cli checksums before
    extracting `-s d` downloads. Dingo owns a separate cardano-cli pin and
    installs it in its own `bin` folder; re-run the Dingo deployment with
    `-s d` when either its rolling node or pinned CLI companion should be
    refreshed.

    When selecting a tag from before this restructuring, download
    `guild-deploy.sh` from that same tag and also pass it with `-b`. For example,
    the existing `node-10.1.4` tag contains the historical flat configuration
    layout, so use its dispatcher together with `-b node-10.1.4`. The tag
    contains the whole historical layout; the current branch intentionally
    carries no compatibility copies or fallback paths.

    `deploy-as-systemd.sh` has been removed. Node and component launchers now
    own `systemd install`, `remove`, and `status` operations; existing `-d`
    install aliases are retained. A cnode refresh moves any previously
    installed copy into `scripts/archive` after the replacement launchers have
    been installed. Review the
    [component-owned unit table](Build/node-implementations.md#component-owned-systemd-units)
    before deleting any locally customized legacy unit. New unit files carry
    a deployment-specific Guild ownership marker, and component removal
    refuses an unrelated same-name unit, including one owned by another Guild
    target. Missing expected unit files are left as no-ops. Units produced by
    the old orchestrator are recognized by their component-specific command or
    description during migration.

!!! danger "Current cnode logging configuration"
    The current Guild cnode configurations use the tracing infrastructure
    introduced in cardano-node 10.4.x rather than the former legacy logging
    layout. Guild Operators does not configure the separate cardano-tracer
    service. Consult the
    [official cardano-tracer documentation](https://github.com/intersectmbo/cardano-node/blob/master/cardano-tracer/docs/cardano-tracer.md)
    if you need it.

    What this means, as a SPO:

      - You will no longer have EKG monitoring, there is equivalent SimplePrometheus backend available in node, which should suffice monitoring setup requirements.
      - The logging will not be sent to JSON file formats, but instead be available to stdout - we have updated all our references to include monitoring logs via journald (which allows electing JSON formats should one want to).
      - Since not only the log locations but also the formats of the logging have changed, we have to temporarily disable blockperf/logmonitor for now, as developers of corresponding tools will need to start from scratch reading newer log formats. This should not impact an average SPO not using those tools.
      - A side-effect change that got introduced is also to update logging for submitapi and dbsync configs to use stdout (thus, journald) instead of log files.

    Lastly, given the changes above, we **strongly** recommend you to make sure you go through upgrade steps for your setup in a non-mainnet environment first!!

This is a generic upgrade reference rather than a guide for one node release.
The supported cnode and companion versions are defined in
`files/node-implementations/cnode/release.json`; always review the corresponding
upstream release notes before upgrading.

- Download the current `guild-deploy.sh` and review its options with
  `guild-deploy.sh -h`. When helper scripts are refreshed, their user-variable
  sections are retained unless `-s s` is selected, and previous copies are
  placed in `scripts/archive`. Static files such as genesis and submit-api
  configuration are not treated as user-maintained backups.

!!! warning "Remember"
    You are expected to provide appropriate environment-specific parameters (eg: custom top level folder [-p], alternate name for top level folder [-t], network flag [-n], any additional components you use, etc) to the examples that pertain to your use case.

- Depending on node release, you may be able to simply perform an update-in-place of scripts and node, or for some cases, you may need to overwrite configs as well. Some Examples below:

    - For an upgrade that changes configuration formats, overwrite the cnode
      configuration with `f`. Check the upstream release notes first. Reapply
      any local configuration changes afterwards; topology, config, and db-sync
      files are backed up in `"${CNODE_HOME}"/files` for comparison.

      ``` bash
      mkdir -p "$HOME/tmp"
      cd "$HOME/tmp"
      curl -sfS -o guild-deploy.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh
      chmod 700 guild-deploy.sh
      ./guild-deploy.sh -s dlfm -b master -n mainnet -t cnode -p /opt/cardano
      ```
    - When an upgrade does not require configuration changes, refresh the
      scripts and selected binaries without `f`. Existing configuration and
      script user variables are preserved:

      ``` bash
      mkdir -p "$HOME/tmp"
      cd "$HOME/tmp"
      curl -sfS -o guild-deploy.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh
      chmod 700 guild-deploy.sh
      ./guild-deploy.sh -s dlm -b master -n mainnet -t cnode -p /opt/cardano
      ```

!!! warning "Beware"
    A cnode upgrade, especially across a major version, may revalidate or
    replay the ledger and take several hours. Test on a relay first and plan
    any database transfer while both source and target nodes are stopped. When
    a compatible snapshot is available, the
    [Mithril client](Scripts/mithril-client.md) can reduce replay time.

- After running the deployment script, select the deployment in your shell to use
  its binaries for commands you type yourself:

``` bash
source "${CNODE_HOME}"/scripts/activate
cardano-cli version
```

### Troubleshooting {: #troubleshooting}

- We've found users often confuse between `$PATH` variable resolution between multiple shell sessions, systemd, etc. While if you only used this guide, the binaries should be in `"${CNODE_HOME}/bin"`, you may have manually downloaded to another location before. To avoid this, you can edit the following files and uncomment and set the following variables to the appropriate paths as per your deployment (eg: `CCLI="${CNODE_HOME}"/bin/cardano-cli` if following above):

    - env : CCLI, CNCLI, CNODEBIN
    - [If applicable] dbsync.sh: DBSYNCBIN
    - [If applicable] submitapi.sh: SUBMITAPIBIN
    - [If applicable] ogmios.sh: OGMIOSBIN

- The above should take care of tools and services. However, you might still have duplicate binaries in your `$PATH` (previous artifacts, re-build using old scripts, etc) - it is best that you remove any old binary files from alternate folders. You can do so by executing the below:

``` bash
whereis bech32 cardano-address cardano-cli cardano-db-sync cardano-hw-cli cardano-node cardano-submit-api cncli ogmios
```

For some cases - you might have no values (eg: you may not use `cardano-db-sync`, `cncli`, `ogmios` and/or `cardano-hw-cli`. You need not take any actions for the binaries you do not use.

- If gLiveView cannot connect after an upgrade, first distinguish a missing
  node process from an unavailable metrics endpoint. Set `DEPLOYMENT_HOME` to
  the affected cnode, Dingo, or Amaru root and inspect the implementation and
  service recorded in its manifest:

  ```bash
  DEPLOYMENT_HOME="${NODE_HOME:-${CNODE_HOME:?set NODE_HOME to the deployment root}}"
  NODE_IMPLEMENTATION="$(jq -er '.implementation' \
    "${DEPLOYMENT_HOME}/.deployment.json")"
  NODE_SERVICE="$(jq -er '.serviceName' \
    "${DEPLOYMENT_HOME}/.deployment.json")"

  case "${NODE_IMPLEMENTATION}" in
    cnode) "${DEPLOYMENT_HOME}/scripts/cnode.sh" systemd status ;;
    dingo|amaru) "${DEPLOYMENT_HOME}/scripts/${NODE_IMPLEMENTATION}.sh" status ;;
  esac
  sudo journalctl -fu "${NODE_SERVICE}.service"
  ```

  Dingo's default metrics endpoint is
  `http://127.0.0.1:12798/metrics`. Amaru's managed collector exposes
  `http://127.0.0.1:8889/metrics`; its launcher status includes the companion
  `${NODE_SERVICE}-metrics.service`, whose journal can be followed with:

  ```bash
  sudo journalctl -fu "${NODE_SERVICE}-metrics.service"
  ```

  cnode obtains its Prometheus address from its node configuration. A node
  that is replaying or revalidating the ledger may take time before all normal
  metrics are available. gLiveView hides individual unsupported metrics, but
  it requires a live process and a successful metrics scrape.

### Unintended update-in-place {: #unintended}

If an update replaced files unintentionally, use the copies in
`"${CNODE_HOME}/scripts/archive"` for a targeted comparison or restoration.
For a deliberate downgrade across a repository restructuring boundary, use
the `guild-deploy.sh` from the chosen existing tag and pass that same tag with
`-b`, as described above. Do not mix one historical helper with the current
runtime and manifest. Available tags are listed
[on GitHub](https://github.com/cardano-community/guild-operators/tags).

### Support/Improvements {: #support}

Hope the guide above helps you with the migration, but again - we could've missed some edge cases. If so, please report via chat in [Koios Discussions channel](https://t.me/CardanoKoios) or open an issue on github. Please DO NOT make edits to the script content based on forum/alternate guide/channels, while done with best intentions - there have been solutions put online that modify files unnecessarily instead of correcting configs and disabling updates, such actions will only cause trouble for future updates.
