#!/bin/bash
echo "$(date +%F_%H:%M:%S) Running stake distribution update..."
psql cexplorer -qbt -c "SELECT GREST.UPDATE_STAKE_DISTRIBUTION_CACHE_CHECK();"
