#! /bin/bash

cd $CNODE_HOME/scripts || return
curl -s -o cntools.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.sh
curl -s -o cntools.config https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.config
curl -s -o cntools.library https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.library
curl -s -o cntoolsBLockCollector.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntoolsBlockCollector.sh
curl -s -o env https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/env
chmod 750 cntools.sh
chmod 640 cntools.config cntools.library env 
cd - || return
