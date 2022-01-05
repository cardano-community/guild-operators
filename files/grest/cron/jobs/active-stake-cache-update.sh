#!/bin/bash
DB_NAME=cexplorer

echo "$(date +%F_%H:%M:%S) Running active stake cache update..."
. ../env offline # will this work (relative path)?

# High level check in db to see if update needed at all (should be updated only once on epoch transition)
! [[ $(psql ${DB_NAME} -qbt -c "SELECT grest.active_stake_cache_update_check();") ]] &&
  echo "No update needed, exiting..." &&
  exit 0;

# 2nd and 3rd number in the logs correspond to number of stakes and epoch number
# Could break due to upstream changes on db-sync
last_epoch_stakes_log=$(grep 'Handling.*.stakes for epoch' "${CNODE_HOME}"/logs/dbsync.json | tail -1 | grep -Eo '[0-9]+' | sed -n 2,3p)
[[ -z ${last_epoch_stakes_log} ]] &&
  echo "Could not find any 'Handling stakes' log entries, exiting..." &&
  exit 1;

logs_last_epoch_stakes_count=$(${last_epoch_stakes_log} | awk 'print ${1}')
logs_last_epoch_no=$(${last_epoch_stakes_log} | awk 'print ${2}')

db_last_epoch_no=$(psql ${DB_NAME} -qbt -c "SELECT grest.get_current_epoch();")
[[ "${db_last_epoch_no}" -ne "${logs_last_epoch_no}" ]] &&
  echo "Mismatch between last epoch in logs and database, exiting..."
  exit 1;

# count current epoch entries
db_epoch_stakes_count=$(psql ${DB_NAME} -qbt -c "SELECT grest.get_epoch_stakes_count(${db_last_epoch_no});")

# check if db-sync completed handling stakes
[[ ${db_epoch_stakes_count} -ne ${logs_last_epoch_stakes_count} ]] &&
  echo "Logs last epoch stakes count: ${logs_last_epoch_stakes_count}" &&
  echo "DB last epoch stakes count: ${db_epoch_stakes_count}" &&
  echo "db-sync stakes handling still incomplete, exiting..." &&
  exit 0;

# If we get this far, it means stakes have been validated, so we run the cache update
psql ${DB_NAME} -qbt -c "SELECT GREST.active_stake_cache_update(${db_last_epoch_no});" 2>&1 1>/dev/null
echo "$(date +%F_%H:%M:%S) Job done!"
