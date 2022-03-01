#!/bin/bash
DB_NAME=cexplorer
. ../env offline

echo "$(date +%F_%H:%M:%S) Running epoch info cache update..."
psql ${DB_NAME} -qbt -c "SELECT GREST.EPOCH_INFO_CACHE_UPDATE(${NWMAGIC});" 2>&1 1>/dev/null
echo "$(date +%F_%H:%M:%S) Job done!"
