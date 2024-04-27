#!/usr/bin/env bash

trap 'killall -s SIGINT cardano-node' SIGINT SIGTERM
# "docker run --init" to enable the docker init proxy
# To manually test: docker kill -s SIGTERM container

head -n 8 ~/.scripts/banner.txt

# shellcheck disable=SC1090
. ~/.bashrc > /dev/null 2>&1

echo "NETWORK: $NETWORK $POOL_NAME $TOPOLOGY";

[[ -z "${CNODE_HOME}" ]] && export CNODE_HOME=/opt/cardano/cnode 
[[ -z "${CNODE_PORT}" ]] && export CNODE_PORT=6000

echo "NODE: $HOSTNAME - Port:$CNODE_PORT - $POOL_NAME";
cardano-node --version;

if [[ "${ENABLE_BACKUP}" == "Y" ]] || [[ "${ENABLE_RESTORE}" == "Y" ]]; then
  [[ ! -d "${CNODE_HOME}"/backup/$NETWORK-db ]] && mkdir -p $CNODE_HOME/backup/$NETWORK-db
  dbsize=$(du -s $CNODE_HOME/db | awk '{print $1}')
  bksizedb=$(du -s $CNODE_HOME/backup/$NETWORK-db 2>/dev/null | awk '{print $1}')
  if [[ "${ENABLE_RESTORE}" == "Y" ]] && [[ "$dbsize" -lt "$bksizedb" ]]; then
    echo "Backup Started"
    cp -rf "${CNODE_HOME}"/backup/"${NETWORK}"-db/* "${CNODE_HOME}"/db 2>/dev/null
    echo "Backup Finished"
  fi

  if [[ "${ENABLE_BACKUP}" == "Y" ]] && [[ "$dbsize" -gt "$bksizedb" ]]; then
    echo "Restore Started"
    cp -rf "${CNODE_HOME}"/db/* "${CNODE_HOME}"/backup/"${NETWORK}"-db/ 2>/dev/null
    echo "Restore Finished"
  fi
fi

# Customisation 
customise () {
  find /opt/cardano/cnode/files -name "*config*.json" -print0 | xargs -0 sed -i 's/127.0.0.1/0.0.0.0/g' > /dev/null 2>&1 
  grep -i ENABLE_CHATTR /opt/cardano/cnode/scripts/cntools.sh >/dev/null && sed -E -i 's/^#?ENABLE_CHATTR=(true|false)?/ENABLE_CHATTR=false/g' /opt/cardano/cnode/scripts/cntools.sh > /dev/null 2>&1
  grep -i ENABLE_DIALOG /opt/cardano/cnode/scripts/cntools.sh >/dev/null && sed -E -i 's/^#?ENABLE_DIALOG=(true|false)?/ENABLE_DIALOG=false/' /opt/cardano/cnode/scripts/cntools.sh > /dev/null 2>&1
  find /opt/cardano/cnode/files -name "*config*.json" -print0 | xargs -0 sed -i 's/\"hasEKG\": 12788,/\"hasEKG\": [\n    \"0.0.0.0\",\n    12788\n],/g' > /dev/null 2>&1
  return 0
}

load_configs () {
  cp -rf /conf/"${NETWORK}"/* "$CNODE_HOME"/files/
}

if [[ -n "${NETWORK}" ]] ; then
  if [[ "${UPDATE_CHECK}" == "Y" ]] ; then
    "$CNODE_HOME"/scripts/guild-deploy.sh -n "$NETWORK" -u -s f > /dev/null 2>&1
  else
    load_configs
  fi
else
  echo "Please set a NETWORK environment variable to one of: mainnet / preview / preprod / guild-mainnet / guild"
  echo "mount a '$CNODE_HOME/priv/files' volume containing: mainnet-config.json, mainnet-shelley-genesis.json, mainnet-byron-genesis.json, and mainnet-topology.json "
  echo "for active nodes set POOL_DIR environment variable where op.cert, hot.skey and vrf.skey files reside. (usually under '${CNODE_HOME}/priv/pool/$POOL_NAME' ) "
  echo "or just set POOL_NAME environment variable (for default path). "
fi

customise \
&& exec "$CNODE_HOME"/scripts/cnode.sh