Simple restart script to restart cardano-node.

#### Download and Configure restart.sh

If you have run [prereqs.sh](basics.md#pre-requisites), this should already be available in your scripts folder.

To download restart.sh manually you can execute the commands below:

```bash
cd $CNODE_HOME/scripts
curl -s -o topologyUpdater.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/restart.sh
chmod 750 restart.sh
```

#### Start the script

Then add the script to be executed every 15 minutes to check for status.

```bash
*/15 * * * * /opt/cardano/cnode/scripts/restart.sh
```

you can check `logs/restart.log` for cardano-node status.
