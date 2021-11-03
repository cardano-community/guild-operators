#!/bin/bash
echo "$(date +%F_%H:%M:%S) Running pool history cache update..."
psql cexplorer -qbt -c "SELECT GREST.pool_history_cache_update();" 2>&1 1>/dev/null
