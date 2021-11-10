#!/bin/bash
DB_NAME=cexplorer

echo "$(date +%F_%H:%M:%S) Running stake distribution update..."
psql ${DB_NAME} -qbt -c "SELECT GREST.UPDATE_STAKE_DISTRIBUTION_CACHE_CHECK();" 2>&1 1>/dev/null
