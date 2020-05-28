### Cardano Node Tools

This is a multi-purpose script to operate various activities (like creating keys, transactions, registering stake pool , delegating to a pool or updating binaries) using cardano node.

The script assumes the [pre-requisites](Common.md#dependencies-and-folder-structure-setup) have already been run.

#### Download cntools.sh

If you have run `prereqs.sh`, this should already be available in your scripts folder and make this step unnecessary. 
To download cntools manually you can execute the commands below:
``` bash
cd $CNODE_HOME/scripts
curl -s -o cntools.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.sh
curl -s -o cntools.config https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.config
curl -s -o cntools.library https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.library
curl -s -o env https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/env
chmod 750 cntools.sh
chmod 640 cntools.config cntools.library env 
```

#### Check Usage

Execute cntools.sh without any arguments to run the tool.

Main Menu
``` bash
./cntools.sh
 >> CNTOOLS <<                                       A Guild Operators collaboration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   Main Menu

   1) update
   2) wallet  [new|list|show|remove|decrypt|encrypt]
   3) funds   [send|delegate]
   4) pool    [new|register]
   q) quit
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

PS: Note that parts of the scripts are under construction, but you would see a message if a particular functionality is unavailable
