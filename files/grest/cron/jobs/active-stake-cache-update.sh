#!/bin/bash
DB_NAME=cexplorer

echo "$(date +%F_%H:%M:%S) Running active stake cache update..."

# High level check in db to see if update needed at all (should be updated only once on epoch transition)
[[ $(psql ${DB_NAME} -qbt -c "SELECT grest.active_stake_cache_update_check();" | tail -2 | tr -cd '[:alnum:]') != 't' ]] &&
  echo "No update needed, exiting..." &&
  exit 0

# This could break due to upstream changes on db-sync (based on log format)
last_epoch_stakes_log=$(grep -r 'Inserted.*.EpochStake for EpochNo ' "$(dirname "$0")"/../../logs/dbsync-*.json "$(dirname "$0")"/../../logs/archive/dbsync-*.json 2>/dev/null | sed -e 's#.*.Inserted ##' -e 's#EpochStake for EpochNo##' -e 's#\"}.*.$##' | sort -k2 -n | tail -1)
[[ -z ${last_epoch_stakes_log} ]] &&
  echo "Could not find any 'Handling stakes' log entries, exiting..." &&
  exit 1

logs_last_epoch_stakes_count=$(echo "${last_epoch_stakes_log}" | cut -d\  -f1)
logs_last_epoch_no=$(echo "${last_epoch_stakes_log}" | cut -d\  -f3)

db_last_epoch_no=$(psql ${DB_NAME} -qbt -c "SELECT grest.get_current_epoch();" | tr -cd '[:alnum:]')
[[ "${db_last_epoch_no}" != "${logs_last_epoch_no}" ]] &&
  echo "Mismatch between last epoch in logs and database, exiting..." &&
  exit 1

# Count current epoch entries processed by db-sync
db_epoch_stakes_count=$(psql ${DB_NAME} -qbt -c "SELECT grest.get_epoch_stakes_count(${db_last_epoch_no});" | tr -cd '[:alnum:]')

# Check if db-sync completed handling stakes
[[ "${db_epoch_stakes_count}" != "${logs_last_epoch_stakes_count}" ]] &&
  echo "Logs last epoch stakes count: ${logs_last_epoch_stakes_count}" &&
  echo "DB last epoch stakes count: ${db_epoch_stakes_count}" &&
  echo "db-sync stakes handling still incomplete, exiting..." &&
  exit 0

# Stakes have been validated, run the cache update
psql ${DB_NAME} -qbt -c "SELECT GREST.active_stake_cache_update(${db_last_epoch_no});" 2>&1 1>/dev/null
echo "$(date +%F_%H:%M:%S) Job done!"
