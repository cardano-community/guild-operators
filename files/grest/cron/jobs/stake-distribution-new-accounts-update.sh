#!/bin/bash
DB_NAME=cexplorer

echo "$(date +%F_%H:%M:%S) Running stake distribution update for new accounts..."
psql ${DB_NAME} -qbt -c "CALL GREST.UPDATE_NEWLY_REGISTERED_ACCOUNTS_STAKE_DISTRIBUTION_CACHE();" 2>&1 1>/dev/null
echo "$(date +%F_%H:%M:%S) Job done!"
