#!/bin/bash
DB_NAME=cexplorer

echo "$(date +%F_%H:%M:%S) Running active stake cache update..."

# High level check in db to see if update needed at all (should be updated only once on epoch transition)
[[ $(psql ${DB_NAME} -qbt -c "SELECT grest.active_stake_cache_update_check();" | tail -2 | tr -cd '[:alnum:]') != 't' ]] &&
  echo "No update needed, exiting..." &&
  exit 0;

# 2nd and 3rd number in the logs correspond to number of stakes and epoch number
# Could break due to upstream changes on db-sync
last_epoch_stakes_log=$(grep 'Handling.*.stakes for epoch' "$(dirname "$0")"/../../logs/dbsync.json | tail -1 | grep -Eo '[0-9]+' | sed -n 2,3p | xargs echo)
[[ -z ${last_epoch_stakes_log} ]] &&
  echo "Could not find any 'Handling stakes' log entries, exiting..." &&
  exit 1;

logs_last_epoch_stakes_count=$(echo "${last_epoch_stakes_log}" | cut -d\  -f1)
logs_last_epoch_no=$(echo "${last_epoch_stakes_log}" | cut -d\  -f2)

db_last_epoch_no=$(psql ${DB_NAME} -qbt -c "SELECT grest.get_current_epoch();" | tr -cd '[:alnum:]')
[[ "${db_last_epoch_no}" != "${logs_last_epoch_no}" ]] &&
  echo "Mismatch between last epoch in logs and database, exiting..." &&
  exit 1;

# count current epoch entries
db_epoch_stakes_count=$(psql ${DB_NAME} -qbt -c "SELECT grest.get_epoch_stakes_count(${db_last_epoch_no});" | tr -cd '[:alnum:]')

# check if db-sync completed handling stakes
[[ "${db_epoch_stakes_count}" != "${logs_last_epoch_stakes_count}" ]] &&
  echo "Logs last epoch stakes count: ${logs_last_epoch_stakes_count}" &&
  echo "DB last epoch stakes count: ${db_epoch_stakes_count}" &&
  echo "db-sync stakes handling still incomplete, exiting..." &&
  exit 0;

# If we get this far, it means stakes have been validated, so we run the cache update
psql ${DB_NAME} -qbt -c "SELECT GREST.active_stake_cache_update(${db_last_epoch_no});" 2>&1 1>/dev/null
echo "$(date +%F_%H:%M:%S) Job done!"
