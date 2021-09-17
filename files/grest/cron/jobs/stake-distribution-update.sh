#!/bin/bash
LOG_DIR="${CNODE_HOME}/logs"
psql cexplorer -c "SELECT GREST.UPDATE_STAKE_DISTRIBUTION_CACHE_CHECK" >> "${LOG_DIR}/stake-distribution-update.log"