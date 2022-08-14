#!/bin/bash
DB_NAME=cexplorer

echo "$(date +%F_%H:%M:%S) Capturing last epochs' snapshot..."
psql ${DB_NAME} -qbt -c "CALL GREST.CAPTURE_LAST_EPOCH_SNAPSHOT();" 2>&1 1>/dev/null
echo "$(date +%F_%H:%M:%S) Job done!"
