#!/bin/bash
DB_NAME=cexplorer

echo "$(date +%F_%H:%M:%S) Running stake distribution update..."
psql ${DB_NAME} -qbt -c "SELECT GREST.STAKE_DISTRIBUTION_CACHE_UPDATE_CHECK();" 2>&1 1>/dev/null
echo "$(date +%F_%H:%M:%S) Job done!"
